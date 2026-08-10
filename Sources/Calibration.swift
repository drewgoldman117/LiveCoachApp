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
