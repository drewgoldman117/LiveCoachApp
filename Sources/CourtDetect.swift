// CourtDetect.swift
//
// Direct port of the Python prototype's src/court_detect.py: find the court
// lines in one frame and fit the homography, with NO user input.
//
// This is why the app has no calibration step. The phone is zip-tied to a
// fence out of arm's reach, so a calibration that needs you to tap its screen
// is unusable, and a hand calibration can never notice the camera got nudged.
// CalibrationView (tapping the 8 corners) remains only as the fallback.
//
// Deliberately CLASSICAL, not a learned keypoint model, for the same reasons
// as the Python: the camera is fixed so this runs once and may be slow, the
// court model is exactly known, and there is no generalization risk (the trap
// the ball model already fell into on unfamiliar courts).
//
// Pipeline: line-structure mask -> Hough -> vanishing-point grouping ->
// exhaustive order-preserving assignment of detected lines to model lines ->
// two-stage scoring (support x completeness) -> ICP refinement against line
// pixels.
//
// PORTING NOTES - every constant here is load-bearing and was derived from a
// real failure in the Python. Read court_detect.py's header and CLAUDE.md's
// "Automatic calibration" section before changing any of them. In particular:
//
//   * There is NO painted line under the net, so the net is absent from
//     modelY. What is visible there is the net TAPE, ~1m above the ground
//     plane; matching it as a ground line biases the whole homography.
//   * Doubles sidelines are assignment CANDIDATES (modelX) and are scored for
//     COMPLETENESS but never for SUPPORT. That asymmetry is the fix for a real
//     bug: with the alley missing from the completeness model, a
//     doubles-as-singles fit scored HIGHER than the correct one (0.2775 vs
//     0.2597 on the sinner clip) because it covered the alley paint while the
//     correct fit left it unexplained. Adding segments can only cover more
//     mask pixels, never fewer, so a court with no doubles lines painted is
//     unaffected.
//
// No UIKit/Vision here on purpose: it is pure arithmetic over a grayscale
// buffer, so it can be compiled and validated against the Python off-device.

import Foundation
import CoreGraphics

// MARK: - Model

/// A line as a*x + b*y + c = 0 with (a,b) a unit normal, sign-normalized so
/// duplicates compare equal.
struct CourtLine {
    var a: Double, b: Double, c: Double

    init(a: Double, b: Double, c: Double) { self.a = a; self.b = b; self.c = c }

    /// From Hough's (rho, theta).
    init(rho: Double, theta: Double) {
        var a = cos(theta), b = sin(theta), c = -rho
        if b < 0 || (b == 0 && a < 0) { a = -a; b = -b; c = -c }
        self.init(a: a, b: b, c: c)
    }

    func distance(to p: CGPoint) -> Double { abs(a * Double(p.x) + b * Double(p.y) + c) }

    /// Point on this line nearest `p`: p pushed back along the unit normal.
    func closestPoint(to p: CGPoint) -> CGPoint {
        let d = a * Double(p.x) + b * Double(p.y) + c
        return CGPoint(x: Double(p.x) - a * d, y: Double(p.y) - b * d)
    }
}

struct CourtDetection {
    let homography: Homography       // image pixels -> court meters
    let homographyInv: Homography    // court meters -> image pixels
    let support: Double              // 0..1 model lines sitting on detected lines
    let completeness: Double         // 0..1 detected lines the model explains
    let linesMatched: Int
    let imagePoints: [CGPoint]       // the 8 landmarks, in CalibrationView tap order
    var score: Double { support * completeness }
}

enum CourtDetect {

    // MARK: - Constants (must match court_detect.py)

    static let doublesHalfWidthM: Double = 5.485

    /// Constant-Y painted lines, FAR -> NEAR. The net is deliberately absent.
    static let modelY: [Double] = [Court.lengthM, Court.farServiceLineY,
                                   Court.nearServiceLineY, 0.0]
    /// Constant-X lines, LEFT -> RIGHT. Doubles included as candidates.
    static let modelX: [Double] = [-doublesHalfWidthM, -Court.halfWidthM, 0.0,
                                   Court.halfWidthM, doublesHalfWidthM]

    static let samplesPerSegment = 48
    static let supportRadiusPx = 4
    static let maxPoolLines = 40
    static let maxHLines = 8
    static let maxVLines = 7
    static let minInFrameFrac = 0.55
    static let minDepthRatio = 0.15
    /// The projected court must be a plausible SIZE in the image, not merely a
    /// plausible shape. Every other gate here is scale-invariant, and that hole
    /// is what let this app adopt a court 40px deep in a 960px frame - 4% of the
    /// height - after latching onto a small cluster of background lines. That
    /// fit satisfied depth ratio (0.46), convexity, ordering and support, and
    /// was saved as the court map. Real courts with the camera behind the
    /// baseline: roy 48% of frame height, dad_clip1 44% even badly mounted.
    static let minCourtHeightFrac = 0.15
    static let shortlistCount = 250
    static let completenessScale = 640.0

    /// Segments scored for SUPPORT: painted on every singles court, so a
    /// correct homography must find support along all of them. Doubles lines
    /// are excluded - a court without them must not be penalised.
    static var scoringSegments: [(CGPoint, CGPoint)] {
        var segs = modelY.map {
            (CGPoint(x: -Court.halfWidthM, y: $0), CGPoint(x: Court.halfWidthM, y: $0))
        }
        segs.append((CGPoint(x: -Court.halfWidthM, y: 0), CGPoint(x: -Court.halfWidthM, y: Court.lengthM)))
        segs.append((CGPoint(x: Court.halfWidthM, y: 0), CGPoint(x: Court.halfWidthM, y: Court.lengthM)))
        segs.append((CGPoint(x: 0, y: Court.nearServiceLineY), CGPoint(x: 0, y: Court.farServiceLineY)))
        return segs
    }

    /// Segments rasterised for COMPLETENESS: everything actually painted on a
    /// doubles-marked court. See the header - omitting the alley inverts this
    /// metric on the very fit it most needs to reject.
    static var completenessSegments: [(CGPoint, CGPoint)] {
        var segs = scoringSegments
        segs.append((CGPoint(x: -doublesHalfWidthM, y: 0), CGPoint(x: -doublesHalfWidthM, y: Court.lengthM)))
        segs.append((CGPoint(x: doublesHalfWidthM, y: 0), CGPoint(x: doublesHalfWidthM, y: Court.lengthM)))
        for y in [0.0, Court.lengthM] {
            segs.append((CGPoint(x: -doublesHalfWidthM, y: y), CGPoint(x: doublesHalfWidthM, y: y)))
        }
        return segs
    }

    /// Court-meter points sampled along every scoring segment.
    static let samples: [CGPoint] = {
        var pts: [CGPoint] = []
        for (p0, p1) in scoringSegments {
            for i in 0..<samplesPerSegment {
                let t = Double(i) / Double(samplesPerSegment - 1)
                pts.append(CGPoint(x: Double(p0.x) + (Double(p1.x) - Double(p0.x)) * t,
                                   y: Double(p0.y) + (Double(p1.y) - Double(p0.y)) * t))
            }
        }
        return pts
    }()

    // MARK: - 1. Line mask

    /// Pixels that look like part of a thin bright line: brighter than
    /// `minBrightness` AND brighter by `minContrast` than the pixels `width`
    /// away on BOTH sides, horizontally or vertically.
    ///
    /// The both-sides test is what makes this work where a plain threshold
    /// fails: a white wall, a sunlit patch or a player's white shirt is bright
    /// but is not brighter than its own interior, so it produces no response.
    /// Only thin structures do.
    static func lineMask(_ gray: [UInt8], width w: Int, height h: Int,
                         lineWidth: Int, minBrightness: Int = 110,
                         minContrast: Int = 18) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: w * h)
        guard lineWidth > 0, w > 2 * lineWidth, h > 2 * lineWidth else { return mask }
        gray.withUnsafeBufferPointer { g in
            for y in lineWidth..<(h - lineWidth) {
                let row = y * w
                for x in lineWidth..<(w - lineWidth) {
                    let v = Int(g[row + x])
                    if v < minBrightness { continue }
                    let isVert = (v - Int(g[row + x - lineWidth]) >= minContrast)
                              && (v - Int(g[row + x + lineWidth]) >= minContrast)
                    let isHorz = (v - Int(g[(y - lineWidth) * w + x]) >= minContrast)
                              && (v - Int(g[(y + lineWidth) * w + x]) >= minContrast)
                    if isVert || isHorz { mask[row + x] = 255 }
                }
            }
        }
        return mask
    }

    /// Square-kernel dilation, matching cv2.dilate with a (2r+1) box.
    static func dilate(_ mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        var tmp = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {                                  // horizontal pass
            let row = y * w
            for x in 0..<w {
                var v: UInt8 = 0
                let lo = max(0, x - r), hi = min(w - 1, x + r)
                for k in lo...hi where mask[row + k] > v { v = mask[row + k] }
                tmp[row + x] = v
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {                                  // vertical pass
            let lo = max(0, y - r), hi = min(h - 1, y + r)
            for x in 0..<w {
                var v: UInt8 = 0
                for k in lo...hi where tmp[k * w + x] > v { v = tmp[k * w + x] }
                out[y * w + x] = v
            }
        }
        return out
    }

    // MARK: - 2. Hough lines

    /// Standard Hough transform over (rho=1px, theta=pi/180), with the same
    /// 4-neighbor non-maximum suppression and descending-vote ordering as
    /// cv2.HoughLines. Vote order matters: the pool is truncated by it, and
    /// truncating by image POSITION instead once discarded the real court
    /// lines (see CLAUDE.md).
    static func houghLines(_ mask: [UInt8], width w: Int, height h: Int,
                           minVotes: Int) -> [CourtLine] {
        let thetaBins = 180
        let diag = Int(ceil((Double(w * w + h * h)).squareRoot()))
        let rhoBins = 2 * diag + 1
        var acc = [Int32](repeating: 0, count: thetaBins * rhoBins)

        var cosT = [Double](repeating: 0, count: thetaBins)
        var sinT = [Double](repeating: 0, count: thetaBins)
        for t in 0..<thetaBins {
            let ang = Double(t) * Double.pi / Double(thetaBins)
            cosT[t] = cos(ang); sinT[t] = sin(ang)
        }

        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] != 0 {
                let fx = Double(x), fy = Double(y)
                for t in 0..<thetaBins {
                    let r = Int((fx * cosT[t] + fy * sinT[t]).rounded()) + diag
                    if r >= 0 && r < rhoBins { acc[t * rhoBins + r] += 1 }
                }
            }
        }

        // Local maxima above threshold. The comparisons are deliberately
        // asymmetric (> on one side, >= on the other), matching OpenCV so a
        // plateau yields one line rather than two.
        var found: [(votes: Int32, idx: Int, rho: Double, theta: Double)] = []
        for t in 1..<(thetaBins - 1) {
            for r in 1..<(rhoBins - 1) {
                let v = acc[t * rhoBins + r]
                if v <= Int32(minVotes) { continue }      // OpenCV: strictly greater
                if v <= acc[t * rhoBins + r - 1] || v < acc[t * rhoBins + r + 1] { continue }
                if v <= acc[(t - 1) * rhoBins + r] || v < acc[(t + 1) * rhoBins + r] { continue }
                found.append((v, found.count, Double(r - diag),
                              Double(t) * Double.pi / Double(thetaBins)))
            }
        }
        // Descending votes, ties broken by discovery order. Swift's sort is not
        // stable, and the order matters: the pool is truncated to maxPoolLines
        // by it, so an arbitrary tie-break silently changes which lines the
        // search ever sees.
        found.sort { $0.votes != $1.votes ? $0.votes > $1.votes : $0.idx < $1.idx }
        return found.map { CourtLine(rho: $0.rho, theta: $0.theta) }
    }

    /// Merge near-duplicate lines so each real court line contributes once.
    static func mergeLines(_ lines: [CourtLine], width w: Int, height h: Int) -> [CourtLine] {
        let diag = (Double(w * w + h * h)).squareRoot()
        var merged: [CourtLine] = []
        for l in lines {
            let dup = merged.contains { m in
                abs(l.a - m.a) < 0.06 && abs(l.b - m.b) < 0.06 && abs(l.c - m.c) < diag * 0.02
            }
            if !dup { merged.append(l) }
        }
        return merged
    }

    // MARK: - 3. Vanishing-point grouping

    static func intersect(_ l1: CourtLine, _ l2: CourtLine) -> CGPoint? {
        let den = l1.a * l2.b - l2.a * l1.b
        guard abs(den) > 1e-9 else { return nil }
        let x = (l1.b * l2.c - l2.b * l1.c) / den
        let y = (l2.a * l1.c - l1.a * l2.c) / den
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// True if `line` points at `vp`. Compared as an ANGLE, not a distance: a
    /// vanishing point can sit thousands of pixels off-frame, where a fixed
    /// pixel tolerance is meaningless, but the angular test stays scale-free.
    private static func supportsVP(_ line: CourtLine, _ vp: CGPoint,
                                   _ center: CGPoint, _ maxAngleDeg: Double) -> Bool {
        let q = line.closestPoint(to: center)
        let vx = Double(vp.x) - Double(q.x), vy = Double(vp.y) - Double(q.y)
        let n = (vx * vx + vy * vy).squareRoot()
        if n < 1e-6 { return true }
        let dx = -line.b, dy = line.a                    // unit direction
        let cosang = abs((dx * vx + dy * vy) / n)
        return cosang >= cos(maxAngleDeg * Double.pi / 180.0)
    }

    /// Split detected lines into the court's two families by VANISHING POINT.
    ///
    /// This cannot be done by image orientation, which is the intuitive
    /// approach and is simply wrong here: from behind the baseline a sideline
    /// is MORE horizontal than vertical, so an |a| vs |b| test files sidelines
    /// as baselines and finds zero sidelines. Clustering by angle fails too -
    /// the left and right sidelines slope opposite ways. What defines the
    /// families is convergence: constant-Y lines meet at one vanishing point,
    /// constant-X lines at another.
    static func groupLines(_ lines: [CourtLine], width w: Int, height h: Int,
                           maxAngleDeg: Double = 2.5) -> ([CourtLine], [CourtLine]) {
        let center = CGPoint(x: Double(w) / 2.0, y: Double(h) / 2.0)
        var pool = lines
        var families: [[CourtLine]] = []
        for _ in 0..<2 {
            if pool.count < 2 { break }
            var bestIdx: [Int] = []
            for i in 0..<(pool.count - 1) {
                for j in (i + 1)..<pool.count {
                    guard let vp = intersect(pool[i], pool[j]) else { continue }
                    var inliers: [Int] = []
                    for (k, l) in pool.enumerated() where supportsVP(l, vp, center, maxAngleDeg) {
                        inliers.append(k)
                    }
                    if inliers.count > bestIdx.count { bestIdx = inliers }
                }
            }
            if bestIdx.count < 2 { break }
            let keep = Set(bestIdx)
            families.append(bestIdx.map { pool[$0] })
            pool = pool.enumerated().filter { !keep.contains($0.offset) }.map { $0.element }
        }
        while families.count < 2 { families.append([]) }
        return (families[0], families[1])
    }

    /// Sort a family the way the court model is ordered: image top->bottom for
    /// constant-Y lines (far court first), left->right for constant-X lines.
    static func orderFamily(_ family: [CourtLine], width w: Int, height h: Int,
                            asHorizontal: Bool) -> [CourtLine] {
        var keyed: [(Double, CourtLine)] = []
        for l in family {
            if asHorizontal {
                if abs(l.b) < 1e-9 { continue }
                keyed.append((-(l.a * (Double(w) / 2) + l.c) / l.b, l))   // y at mid-width
            } else {
                if abs(l.a) < 1e-9 { continue }
                keyed.append((-(l.b * (Double(h) / 2) + l.c) / l.a, l))   // x at mid-height
            }
        }
        keyed.sort { $0.0 < $1.0 }
        return keyed.map { $0.1 }
    }

    // MARK: - 4. Scoring

    /// Fraction of model-line sample points landing on a (dilated) line pixel.
    /// Scored against ALL samples, not just visible ones, so a homography that
    /// pushes most of the court off-screen can't score well on the sliver left.
    static func scoreHomography(_ hInv: Homography, support: [UInt8],
                                width w: Int, height h: Int) -> (support: Double, inFrac: Double) {
        var hits = 0, inside = 0
        let m = hInv.m
        for p in samples {
            let x = Double(p.x), y = Double(p.y)
            let z = m[6] * x + m[7] * y + m[8]
            guard abs(z) > 1e-9 else { continue }
            let px = (m[0] * x + m[1] * y + m[2]) / z
            let py = (m[3] * x + m[4] * y + m[5]) / z
            guard px >= 0, px < Double(w), py >= 0, py < Double(h) else { continue }
            inside += 1
            if support[Int(py) * w + Int(px)] > 0 { hits += 1 }
        }
        let n = Double(samples.count)
        return (Double(hits) / n, Double(inside) / n)
    }

    /// Fraction of detected line pixels the projected court model EXPLAINS.
    ///
    /// The search is worthless without this. Support alone asks only "do the
    /// model's lines sit on white lines?", which a wrong fit answers perfectly:
    /// a court is a nest of parallel lines, so mapping the whole model onto
    /// just the service box puts every sample on real paint and scores ~1.0
    /// while being hundreds of meters wrong. Completeness asks the reverse.
    static func completeness(_ hInv: Homography, smallMask: [UInt8],
                             width sw: Int, height sh: Int, scale: Double) -> Double {
        var canvas = [UInt8](repeating: 0, count: sw * sh)
        for (a, b) in completenessSegments {
            let pa = hInv.apply(a), pb = hInv.apply(b)
            guard Double(pa.x).isFinite, Double(pb.x).isFinite else { return 0 }
            drawThickLine(&canvas, width: sw, height: sh,
                          x0: Int(Double(pa.x) * scale), y0: Int(Double(pa.y) * scale),
                          x1: Int(Double(pb.x) * scale), y1: Int(Double(pb.y) * scale),
                          thickness: 5)
        }
        var total = 0, covered = 0
        for i in 0..<(sw * sh) where smallMask[i] > 0 {
            total += 1
            if canvas[i] > 0 { covered += 1 }
        }
        return total == 0 ? 0 : Double(covered) / Double(total)
    }

    /// Brush offsets for a DISC of the given radius, computed once.
    ///
    /// A disc, not a square. Stamping a square along a Bresenham line gives a
    /// band whose perpendicular width grows with the line's angle - up to a
    /// factor of sqrt(2) on a diagonal - so diagonal sidelines covered more mask
    /// pixels than cv2.line would and completeness came out inflated. That is
    /// not cosmetic: completeness RANKS the hypotheses, and the inflation
    /// changed which fit won (on the screenrec frame it picked one 6.25m away
    /// from the Python's while scoring higher). A disc gives a constant
    /// perpendicular half-width at every angle, which is what cv2.line does.
    private static let discOffsets: [Int: [(Int, Int)]] = {
        var table: [Int: [(Int, Int)]] = [:]
        for r in 0...4 {
            var offs: [(Int, Int)] = []
            for dy in -r...r {
                for dx in -r...r where dx * dx + dy * dy <= r * r + r {
                    offs.append((dx, dy))
                }
            }
            table[r] = offs
        }
        return table
    }()

    /// Bresenham with a disc brush, standing in for cv2.line(thickness:).
    private static func drawThickLine(_ buf: inout [UInt8], width w: Int, height h: Int,
                                      x0: Int, y0: Int, x1: Int, y1: Int, thickness: Int) {
        // Reject absurd coordinates rather than looping millions of times on a
        // degenerate projection.
        let limit = 100_000
        guard abs(x0) < limit, abs(y0) < limit, abs(x1) < limit, abs(y1) < limit else { return }
        let r = min(4, thickness / 2)
        let brush = discOffsets[r] ?? [(0, 0)]
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            // Bounds-check each stamped pixel. A wrong hypothesis projects the
            // model far off-canvas, and building `max(0, y-r)...min(h-1, y+r)`
            // there yields an invalid range (lower > upper) that TRAPS rather
            // than drawing nothing - the crash this guard exists to prevent.
            for (ox, oy) in brush {
                let yy = y + oy, xx = x + ox
                if yy >= 0 && yy < h && xx >= 0 && xx < w { buf[yy * w + xx] = 255 }
            }
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    // MARK: - 5. Pose plausibility

    private static func corners(_ hInv: Homography) -> [CGPoint]? {
        let court = [CGPoint(x: -Court.halfWidthM, y: Court.lengthM),
                     CGPoint(x: Court.halfWidthM, y: Court.lengthM),
                     CGPoint(x: Court.halfWidthM, y: 0),
                     CGPoint(x: -Court.halfWidthM, y: 0)]
        let pts = court.map { hInv.apply($0) }
        for p in pts where !Double(p.x).isFinite || !Double(p.y).isFinite { return nil }
        return pts
    }

    static func depthRatio(_ hInv: Homography) -> Double {
        guard let c = corners(hInv) else { return 0 }
        let near = hypot(Double(c[2].x - c[3].x), Double(c[2].y - c[3].y))
        let far = hypot(Double(c[1].x - c[0].x), Double(c[1].y - c[0].y))
        return near < 1e-6 ? 0 : far / near
    }

    /// Is this a physically sensible camera pose for THIS product?
    ///
    /// The depth ratio alone isn't enough. A court is ruled in two directions,
    /// so a hypothesis that maps the model ROTATED ~90 degrees still lands on
    /// real paint and scores well. The camera is pinned behind its own baseline
    /// looking up-court, which makes the real constraints cheap: the far edge
    /// sits entirely above the near edge, left stays left of right, the far
    /// edge is the narrower one, and the quad is convex.
    static func plausiblePose(_ hInv: Homography, frameHeight: Double? = nil) -> Bool {
        guard let c = corners(hInv) else { return false }
        let fl = c[0], fr = c[1], nr = c[2], nl = c[3]
        if !(fl.x < fr.x && nl.x < nr.x) { return false }              // not mirrored
        if max(fl.y, fr.y) >= min(nl.y, nr.y) { return false }         // far above near
        let ratio = depthRatio(hInv)
        if !(ratio >= minDepthRatio && ratio <= 0.9) { return false }  // far edge narrower
        // Plausible SIZE, not just shape - see minCourtHeightFrac. Everything
        // above is scale-invariant, so a court shrunk onto a stray cluster of
        // background lines passes all of it.
        if let fh = frameHeight {
            let depthPx = min(Double(nl.y), Double(nr.y)) - max(Double(fl.y), Double(fr.y))
            if depthPx < minCourtHeightFrac * fh { return false }
        }
        var signs = 0.0                                                // convex, no bow-tie
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) % 4], d = c[(i + 2) % 4]
            let cross = (Double(b.x) - Double(a.x)) * (Double(d.y) - Double(b.y))
                      - (Double(b.y) - Double(a.y)) * (Double(d.x) - Double(b.x))
            signs += cross >= 0 ? 1 : -1
        }
        return abs(signs) == 4
    }

    // MARK: - 6. Exact 4-point solve

    /// cv2.getPerspectiveTransform: the exact homography through 4 pairs, via
    /// an 8x8 solve. Used instead of the DLT for the inner search loop because
    /// it runs ~200k times and is far cheaper than an eigen decomposition.
    static func perspective4(from src: [CGPoint], to dst: [CGPoint]) -> Homography? {
        guard src.count == 4, dst.count == 4 else { return nil }
        var a = [Double](repeating: 0, count: 8 * 9)     // augmented 8x9
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            let r0 = (2 * i) * 9
            a[r0 + 0] = x; a[r0 + 1] = y; a[r0 + 2] = 1
            a[r0 + 6] = -u * x; a[r0 + 7] = -u * y; a[r0 + 8] = u
            let r1 = (2 * i + 1) * 9
            a[r1 + 3] = x; a[r1 + 4] = y; a[r1 + 5] = 1
            a[r1 + 6] = -v * x; a[r1 + 7] = -v * y; a[r1 + 8] = v
        }
        // Gaussian elimination with partial pivoting.
        for col in 0..<8 {
            var piv = col
            for r in (col + 1)..<8 where abs(a[r * 9 + col]) > abs(a[piv * 9 + col]) { piv = r }
            if abs(a[piv * 9 + col]) < 1e-12 { return nil }
            if piv != col {
                for k in 0...8 { a.swapAt(col * 9 + k, piv * 9 + k) }
            }
            let d = a[col * 9 + col]
            for k in col...8 { a[col * 9 + k] /= d }
            for r in 0..<8 where r != col {
                let f = a[r * 9 + col]
                if f == 0 { continue }
                for k in col...8 { a[r * 9 + k] -= f * a[col * 9 + k] }
            }
        }
        var m = [Double](repeating: 0, count: 9)
        for i in 0..<8 { m[i] = a[i * 9 + 8] }
        m[8] = 1
        for v in m where !v.isFinite { return nil }
        return Homography(m)
    }

    // MARK: - 7. ICP refinement

    /// Distance transform plus the coordinates of the nearest line pixel, the
    /// equivalent of cv2.distanceTransformWithLabels. Two-pass vector
    /// propagation (8SSEDT): each pixel inherits its neighbours' nearest-source
    /// coordinate when that is closer than what it already has.
    static func nearestLinePixels(_ mask: [UInt8], width w: Int, height h: Int)
        -> (dist: [Float], nx: [Int32], ny: [Int32]) {
        let big: Float = 1e10
        var dist = [Float](repeating: big, count: w * h)
        var nx = [Int32](repeating: -1, count: w * h)
        var ny = [Int32](repeating: -1, count: w * h)
        for i in 0..<(w * h) where mask[i] != 0 {
            dist[i] = 0; nx[i] = Int32(i % w); ny[i] = Int32(i / w)
        }
        @inline(__always)
        func relax(_ i: Int, _ j: Int, _ x: Int, _ y: Int) {
            guard nx[j] >= 0 else { return }
            let dx = Double(x) - Double(nx[j]), dy = Double(y) - Double(ny[j])
            let d = Float((dx * dx + dy * dy).squareRoot())
            if d < dist[i] { dist[i] = d; nx[i] = nx[j]; ny[i] = ny[j] }
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if x > 0 { relax(i, i - 1, x, y) }
                if y > 0 {
                    relax(i, i - w, x, y)
                    if x > 0 { relax(i, i - w - 1, x, y) }
                    if x < w - 1 { relax(i, i - w + 1, x, y) }
                }
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                if x < w - 1 { relax(i, i + 1, x, y) }
                if y < h - 1 {
                    relax(i, i + w, x, y)
                    if x < w - 1 { relax(i, i + w + 1, x, y) }
                    if x > 0 { relax(i, i + w - 1, x, y) }
                }
            }
        }
        return (dist, nx, ny)
    }

    /// Snap a homography onto the actual line pixels, ICP-style.
    ///
    /// This is what fixes precision, and matching whole LINES cannot substitute
    /// for it: a 4-point fit off slightly-imprecise Hough lines is itself
    /// imprecise, and a line-matching refit is defeated by the singles/doubles
    /// ambiguity (it matches all four sidelines at once and refines against a
    /// contaminated set). Working from PIXELS sidesteps that: project the
    /// model, pull each sample onto the nearest real line pixel, re-solve,
    /// repeat with a shrinking capture radius so far-off clutter stops voting.
    static func icpRefine(_ h: Homography, _ hInv: Homography,
                          dist: [Float], nx: [Int32], ny: [Int32],
                          width w: Int, height hgt: Int, iters: Int = 6) -> (Homography, Homography) {
        var curH = h, curHInv = hInv
        for it in 0..<iters {
            let tol = max(3.0, 14.0 * (1.0 - Double(it) / Double(max(1, iters - 1))) + 3.0)
            var srcPx: [CGPoint] = [], dstCourt: [CGPoint] = []
            let m = curHInv.m
            for p in samples {
                let x = Double(p.x), y = Double(p.y)
                let z = m[6] * x + m[7] * y + m[8]
                guard abs(z) > 1e-9 else { continue }
                let px = (m[0] * x + m[1] * y + m[2]) / z
                let py = (m[3] * x + m[4] * y + m[5]) / z
                guard px >= 0, px < Double(w), py >= 0, py < Double(hgt) else { continue }
                let idx = Int(py) * w + Int(px)
                guard nx[idx] >= 0, Double(dist[idx]) <= tol else { continue }
                srcPx.append(CGPoint(x: Double(nx[idx]), y: Double(ny[idx])))
                dstCourt.append(p)
            }
            guard srcPx.count >= 12,
                  let fit = Homography.find(from: srcPx, to: dstCourt),
                  let fitInv = fit.inverse,
                  plausiblePose(fitInv, frameHeight: Double(hgt)) else { break }
            curH = fit; curHInv = fitInv
        }
        return (curH, curHInv)
    }

    // MARK: - 8. The search

    private static func search(hs: [CourtLine], vs: [CourtLine],
                               mask: [UInt8], support: [UInt8],
                               width w: Int, height h: Int) -> CourtDetection? {
        let scale = completenessScale / Double(max(w, h))
        let sw = Int(Double(w) * scale), sh = Int(Double(h) * scale)
        var smallMask = [UInt8](repeating: 0, count: sw * sh)
        for y in 0..<sh {                                  // INTER_NEAREST
            let sy = min(h - 1, Int(Double(y) / scale))
            for x in 0..<sw {
                smallMask[y * sw + x] = mask[sy * w + min(w - 1, Int(Double(x) / scale))]
            }
        }

        // Stage 1: rank every order-preserving assignment by cheap support.
        // Detected lines are already sorted the way the model is, so a valid
        // assignment must preserve order - which is what makes a full
        // enumeration affordable.
        var shortlist: [(Double, Homography, Homography)] = []
        for i in 0..<max(0, hs.count - 1) {
            for j in (i + 1)..<hs.count {
                for p in 0..<(modelY.count - 1) {
                    for q in (p + 1)..<modelY.count {
                        for k in 0..<max(0, vs.count - 1) {
                            for l in (k + 1)..<vs.count {
                                for r in 0..<(modelX.count - 1) {
                                    for s in (r + 1)..<modelX.count {
                                        var img: [CGPoint] = [], court: [CGPoint] = []
                                        var ok = true
                                        for (hl, my) in [(hs[i], modelY[p]), (hs[j], modelY[q])] {
                                            for (vl, mx) in [(vs[k], modelX[r]), (vs[l], modelX[s])] {
                                                guard let pt = intersect(hl, vl) else { ok = false; break }
                                                img.append(pt)
                                                court.append(CGPoint(x: mx, y: my))
                                            }
                                            if !ok { break }
                                        }
                                        guard ok, let hh = perspective4(from: img, to: court),
                                              let hi = hh.inverse else { continue }
                                        guard plausiblePose(hi, frameHeight: Double(h)) else { continue }  // cheap reject first
                                        let (sc, inFrac) = scoreHomography(hi, support: support,
                                                                           width: w, height: h)
                                        if inFrac < minInFrameFrac || sc < 0.5 { continue }
                                        shortlist.append((sc, hh, hi))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if shortlist.isEmpty { return nil }
        shortlist.sort { $0.0 > $1.0 }

        // Stage 2: REFINE EVERY shortlisted candidate, THEN rank. Ranking on
        // the raw score first is the bug this replaced: the CORRECT hypothesis
        // can score below a doubles-sideline fit purely because its unrefined
        // 4-point fit is rough, and gets eliminated before refinement can close
        // the gap. Refining a top-N by raw score fails identically.
        // "Every candidate" does not mean "every DUPLICATE". Most of the
        // shortlist is the same pose reached by different line-to-model
        // assignments, and refining each copy is the single biggest cost in
        // detection. Measured on 200 ground-truth broadcast frames, collapsing
        // them took a detection from 13.9s to 4.1s with accuracy unmoved
        // (median keypoint error 2.28px -> 2.37px, 97.5% within 7px either
        // way). Merging on where a fit puts the court CORNERS discards only
        // work with no information in it, and the 12px grid is far finer than
        // the doubles/singles ambiguity (1.37m - tens of px in the near court),
        // so the fit this ranking exists to protect still survives separately.
        //
        // The SCAN is bounded, and that bound is not incidental: the shortlist
        // can hold tens of thousands of hypotheses, and projecting corners for
        // every one of them cost more than the ICP calls it saved - it made the
        // Swift SLOWER (a 3K frame went 2.0s -> 3.5s) even while the same change
        // made Python 3.4x faster, because compiled ICP is cheap enough that the
        // scan dominates. The list is score-sorted, so the top slice holds every
        // pose worth refining.
        var unique: [(Double, Homography, Homography)] = []
        var seenPoses = Set<[Int]>()
        for cand in shortlist.prefix(shortlistCount * 8) {
            guard let c = corners(cand.2) else { continue }
            let key = c.flatMap {
                [Int((Double($0.x) / 12).rounded()), Int((Double($0.y) / 12).rounded())]
            }
            if seenPoses.contains(key) { continue }
            seenPoses.insert(key)
            unique.append(cand)
            if unique.count >= shortlistCount { break }
        }

        let (dist, nx, ny) = nearestLinePixels(mask, width: w, height: h)
        var best: (Homography, Homography)? = nil
        var bestCombined = -1.0
        for (_, hh, hi) in unique {
            var cand = icpRefine(hh, hi, dist: dist, nx: nx, ny: ny, width: w, height: h)
            if !plausiblePose(cand.1, frameHeight: Double(h)) { cand = (hh, hi) }
            let sup = scoreHomography(cand.1, support: support, width: w, height: h).support
            let comp = completeness(cand.1, smallMask: smallMask, width: sw, height: sh, scale: scale)
            if sup * comp > bestCombined { bestCombined = sup * comp; best = cand }
        }
        guard let (bh, bhi) = best else { return nil }

        let sup = scoreHomography(bhi, support: support, width: w, height: h).support
        let comp = completeness(bhi, smallMask: smallMask, width: sw, height: sh, scale: scale)
        let matched = countMatched(bhi, hs: hs, vs: vs)
        let pts = Court.corners.map { bhi.apply($0) }
        return CourtDetection(homography: bh, homographyInv: bhi, support: sup,
                              completeness: comp, linesMatched: matched, imagePoints: pts)
    }

    private static func countMatched(_ hInv: Homography, hs: [CourtLine], vs: [CourtLine],
                                     tolPx: Double = 12.0) -> Int {
        var n = 0
        for val in modelY {
            let pa = hInv.apply(CGPoint(x: -Court.halfWidthM, y: val))
            let pb = hInv.apply(CGPoint(x: Court.halfWidthM, y: val))
            if hs.contains(where: { 0.5 * ($0.distance(to: pa) + $0.distance(to: pb)) < tolPx }) { n += 1 }
        }
        for val in modelX {
            let pa = hInv.apply(CGPoint(x: val, y: 0))
            let pb = hInv.apply(CGPoint(x: val, y: Court.lengthM))
            if vs.contains(where: { 0.5 * ($0.distance(to: pa) + $0.distance(to: pb)) < tolPx }) { n += 1 }
        }
        return n
    }

    // MARK: - 9. Entry point

    /// Find the court in a grayscale frame. Returns nil if none is found.
    ///
    /// Costs seconds - never call this on the capture thread. LiveCourt owns
    /// the background execution and the retry/drift policy.
    static func detect(gray: [UInt8], width w: Int, height h: Int,
                       lineWidth: Int? = nil) -> CourtDetection? {
        precondition(gray.count == w * h, "gray buffer must be w*h")
        let widths: [Int]
        if let lw = lineWidth {
            widths = [lw]
        } else {
            widths = Array(Set([max(2, Int((Double(w) / 640).rounded(.toNearestOrEven))),
                                max(2, Int((Double(w) / 380).rounded(.toNearestOrEven))),
                                max(3, Int((Double(w) / 220).rounded(.toNearestOrEven)))])).sorted()
        }

        var best: CourtDetection? = nil
        for lw in widths {
            let mask = lineMask(gray, width: w, height: h, lineWidth: lw)
            let support = dilate(mask, width: w, height: h, radius: supportRadiusPx)

            // Enough votes to be a court line, scaled to the frame; back off
            // until there are enough candidates to group.
            var famA: [CourtLine] = [], famB: [CourtLine] = []
            for frac in [0.28, 0.18, 0.11, 0.07] {
                let votes = max(40, Int(Double(h) * frac))
                let raw = houghLines(mask, width: w, height: h, minVotes: votes)
                let pool = Array(mergeLines(raw, width: w, height: h).prefix(maxPoolLines))
                (famA, famB) = groupLines(pool, width: w, height: h)
                if famA.count >= 2 && famB.count >= 2 { break }
            }
            if famA.count < 2 || famB.count < 2 { continue }

            // Which family is the constant-Y one isn't known up front, and any
            // heuristic for it would be fragile - so try both and let the score
            // decide. Costs one extra search, buys robustness to camera pose.
            for (horiz, vert) in [(famA, famB), (famB, famA)] {
                let hs = Array(orderFamily(horiz, width: w, height: h, asHorizontal: true).prefix(maxHLines))
                let vs = Array(orderFamily(vert, width: w, height: h, asHorizontal: false).prefix(maxVLines))
                if hs.count < 2 || vs.count < 2 { continue }
                if let cand = search(hs: hs, vs: vs, mask: mask, support: support, width: w, height: h),
                   best == nil || cand.score > best!.score {
                    best = cand
                }
            }
        }
        return best
    }
}
