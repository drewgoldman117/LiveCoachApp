// Homography.swift
//
// Pure-Swift replacement for the two cv2 calls the Python prototype relies on:
//   cv2.findHomography(src, dst)        -> Homography.find(from:to:)
//   cv2.perspectiveTransform(pt, H)     -> Homography.apply(_:)
//
// find() implements the same normalized Direct Linear Transform (DLT) that
// OpenCV's findHomography uses with the default (least-squares) method: it fits
// a 3x3 projective transform from N >= 4 point correspondences, minimizing
// algebraic error. Using more than 4 points (we calibrate on 6-8) makes the fit
// far less sensitive to any single click being a few pixels off -- exactly the
// reason calibrate.py uses findHomography rather than the exact 4-point solve.
//
// The homogeneous null-space solve uses LAPACK (dsyev via Accelerate): we form
// the 9x9 normal matrix AᵀA and take the eigenvector of its smallest eigenvalue.

import Foundation
import CoreGraphics
import Accelerate

struct Homography {
    /// Row-major 3x3 matrix, length 9.
    let m: [Double]

    init(_ m: [Double]) { precondition(m.count == 9); self.m = m }

    /// Map a point through the homography (perspectiveTransform for one point).
    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let denom = m[6] * x + m[7] * y + m[8]
        guard abs(denom) > 1e-12 else { return CGPoint(x: 0, y: 0) }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / denom,
                       y: (m[3] * x + m[4] * y + m[5]) / denom)
    }

    /// Inverse transform (e.g. court-meters -> image pixels for drawing lines).
    var inverse: Homography? {
        guard let inv = Homography.invert3x3(m) else { return nil }
        return Homography(inv)
    }

    // MARK: - Fitting

    /// Least-squares homography from `src` points to `dst` points (>= 4 pairs).
    static func find(from src: [CGPoint], to dst: [CGPoint]) -> Homography? {
        guard src.count >= 4, src.count == dst.count else { return nil }

        // Hartley normalization of each point set (crucial for a stable DLT).
        guard let (srcN, tSrc) = normalize(src),
              let (dstN, tDst) = normalize(dst) else { return nil }

        // Build A (2N x 9) for the homogeneous system A h = 0.
        let n = src.count
        var A = [Double](repeating: 0, count: 2 * n * 9)
        for i in 0..<n {
            let x = Double(srcN[i].x), y = Double(srcN[i].y)
            let X = Double(dstN[i].x), Y = Double(dstN[i].y)
            let r0 = (2 * i) * 9
            A[r0 + 0] = -x; A[r0 + 1] = -y; A[r0 + 2] = -1
            A[r0 + 6] = X * x; A[r0 + 7] = X * y; A[r0 + 8] = X
            let r1 = (2 * i + 1) * 9
            A[r1 + 3] = -x; A[r1 + 4] = -y; A[r1 + 5] = -1
            A[r1 + 6] = Y * x; A[r1 + 7] = Y * y; A[r1 + 8] = Y
        }

        // Normal matrix ATA (9x9), then smallest-eigenvalue eigenvector.
        var ATA = [Double](repeating: 0, count: 81)
        for r in 0..<9 {
            for c in 0..<9 {
                var s = 0.0
                for k in 0..<(2 * n) { s += A[k * 9 + r] * A[k * 9 + c] }
                ATA[r * 9 + c] = s
            }
        }
        guard let h = smallestEigenvector(symmetric9x9: ATA) else { return nil }

        // Hn is the homography between NORMALIZED coords. Denormalize:
        //   H = tDst⁻¹ · Hn · tSrc
        let Hn = h  // 9, row-major
        guard let tDstInv = invert3x3(tDst) else { return nil }
        let H = mul3x3(mul3x3(tDstInv, Hn), tSrc)

        // Normalize so H[8] == 1 (matches OpenCV's convention).
        let s = H[8]
        guard abs(s) > 1e-12 else { return nil }
        return Homography(H.map { $0 / s })
    }

    // MARK: - Helpers

    /// Translate centroid to origin and scale so mean distance is sqrt(2).
    /// Returns normalized points and the 3x3 transform T (row-major).
    private static func normalize(_ pts: [CGPoint]) -> ([CGPoint], [Double])? {
        let n = Double(pts.count)
        guard n > 0 else { return nil }
        let mx = pts.reduce(0.0) { $0 + Double($1.x) } / n
        let my = pts.reduce(0.0) { $0 + Double($1.y) } / n
        let meanDist = pts.reduce(0.0) {
            $0 + hypot(Double($1.x) - mx, Double($1.y) - my)
        } / n
        guard meanDist > 1e-12 else { return nil }
        let s = (2.0).squareRoot() / meanDist
        let T = [s, 0, -s * mx,
                 0, s, -s * my,
                 0, 0, 1]
        let out = pts.map { p -> CGPoint in
            CGPoint(x: s * (Double(p.x) - mx), y: s * (Double(p.y) - my))
        }
        return (out, T)
    }

    private static func mul3x3(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                r[i * 3 + j] = a[i * 3 + 0] * b[0 * 3 + j]
                             + a[i * 3 + 1] * b[1 * 3 + j]
                             + a[i * 3 + 2] * b[2 * 3 + j]
            }
        }
        return r
    }

    static func invert3x3(_ m: [Double]) -> [Double]? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12 else { return nil }
        let invDet = 1.0 / det
        return [
            (e * i - f * h) * invDet, (c * h - b * i) * invDet, (b * f - c * e) * invDet,
            (f * g - d * i) * invDet, (a * i - c * g) * invDet, (c * d - a * f) * invDet,
            (d * h - e * g) * invDet, (b * g - a * h) * invDet, (a * e - b * d) * invDet,
        ]
    }

    /// Eigenvector of the smallest eigenvalue of a 9x9 symmetric matrix
    /// (row-major input). Uses LAPACK dsyev; eigenvalues come back ascending,
    /// so the first eigenvector is what we want.
    private static func smallestEigenvector(symmetric9x9 a: [Double]) -> [Double]? {
        var jobz = Int8(UInt8(ascii: "V"))   // eigenvalues + eigenvectors
        var uplo = Int8(UInt8(ascii: "U"))
        var n = __CLPK_integer(9)
        var lda = n
        var mat = a                          // symmetric -> row/col-major equivalent
        var w = [Double](repeating: 0, count: 9)
        var info = __CLPK_integer(0)

        // Workspace query.
        var wkopt = 0.0
        var lwork = __CLPK_integer(-1)
        dsyev_(&jobz, &uplo, &n, &mat, &lda, &w, &wkopt, &lwork, &info)
        guard info == 0 else { return nil }
        lwork = __CLPK_integer(wkopt)
        var work = [Double](repeating: 0, count: Int(lwork))
        dsyev_(&jobz, &uplo, &n, &mat, &lda, &w, &work, &lwork, &info)
        guard info == 0 else { return nil }

        // dsyev overwrites `mat` with eigenvectors as COLUMNS (column-major).
        // Smallest eigenvalue is column 0 -> elements 0..<9.
        return Array(mat[0..<9])
    }
}
