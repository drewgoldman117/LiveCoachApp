// Calibration.swift
//
// Mirrors the JSON that calibrate.py writes (homography + inverse + raw image
// points + frame size), but stored in the app's Documents directory so it
// survives relaunches. One calibration per camera framing; re-run whenever the
// phone moves.

import Foundation
import CoreGraphics

struct Calibration: Codable {
    var frameWidth: Int
    var frameHeight: Int
    var imagePoints: [[Double]]     // tapped pixel points, in click order
    var homography: [Double]        // 3x3 row-major: image pixels -> court meters
    var homographyInv: [Double]     // 3x3 row-major: court meters -> image pixels

    var H: Homography { Homography(homography) }
    var Hinv: Homography { Homography(homographyInv) }

    /// Map an image-pixel point to court meters.
    func toCourt(_ p: CGPoint) -> CGPoint { H.apply(p) }
    /// Map a court-meter point back to image pixels.
    func toImage(_ p: CGPoint) -> CGPoint { Hinv.apply(p) }

    // MARK: - Changing pixel space

    /// The same court map expressed against an image `k` times larger.
    ///
    /// A homography is tied to the pixel grid it was fitted on, and this app
    /// has two of them: court detection runs on a downscale, while Vision and
    /// every overlay work on the full camera buffer. Converting between them is
    /// a similarity on the IMAGE side only - the court-meter side is untouched
    /// - so H composes with a 1/k scale on its input, and Hinv with a k scale
    /// on its output.
    func scaled(by k: Double) -> Calibration {
        guard k > 0, k != 1 else { return self }
        var h = homography, hi = homographyInv
        for r in 0..<3 { h[r * 3] /= k; h[r * 3 + 1] /= k }   // H: (image/k) -> meters
        for c in 0..<6 { hi[c] *= k }                          // Hinv: meters -> image*k
        return Calibration(frameWidth: Int((Double(frameWidth) * k).rounded()),
                           frameHeight: Int((Double(frameHeight) * k).rounded()),
                           imagePoints: imagePoints.map { [$0[0] * k, $0[1] * k] },
                           homography: h, homographyInv: hi)
    }

    /// This map re-expressed for a frame `width` pixels wide - used to score a
    /// stored (native-space) map against a detection-space line mask.
    func scaled(toFrameWidth width: Int) -> Calibration {
        scaled(by: Double(width) / Double(frameWidth))
    }

    // MARK: - Build from tapped points

    /// Fit from the points the user tapped (pixel space) against the known
    /// court coordinates for however many points were placed (>= 4). The click
    /// order follows Court.corners, so N tapped points pair with the first N
    /// court corners (drop the near-baseline pair -> calibrate on 6).
    static func fit(imagePoints pts: [CGPoint], frameWidth: Int, frameHeight: Int) -> Calibration? {
        let n = pts.count
        guard n >= 4, n <= Court.corners.count else { return nil }
        let court = Array(Court.corners.prefix(n))
        guard let h = Homography.find(from: pts, to: court),
              let hInv = h.inverse else { return nil }
        return Calibration(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            imagePoints: pts.map { [Double($0.x), Double($0.y)] },
            homography: h.m,
            homographyInv: hInv.m
        )
    }

    // MARK: - Persistence (Documents/calibration.json)

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("calibration.json")
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Calibration.fileURL, options: .atomic)
    }

    static func load() -> Calibration? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Calibration.self, from: data)
    }

    /// Throw away the saved court map so the next session detects a fresh one.
    ///
    /// Needed because a WRONG fit is sticky: it gets saved, seeds the next
    /// session, and `LiveCourt` only re-detects when the current fit stops
    /// matching the paint. A confidently-wrong court clears that bar and would
    /// otherwise persist forever, with no way to say "no, that's not it".
    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
