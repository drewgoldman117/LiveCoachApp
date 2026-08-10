// Detectors.swift
//
// On-device port of the two-model detection core from the Python prototype:
//   - PlayerDetector.mlpackage (YOLOv8n, COCO person) -> player boxes; foot =
//     bbox bottom-center, mapped to court meters, ID-tracked + smoothed.
//   - BallDetector.mlpackage (RJTPP tennis-ball) -> ball candidates, chosen by
//     trajectory consistency + court bounds (ports ball_tracker.py's selection).
//
// Both models were exported with a FIXED input shape (640 / 1280) and NMS baked
// in, so Vision returns VNRecognizedObjectObservation directly and CoreML keeps
// them on the Neural Engine. Vision reports boxes in the ORIGINAL image's
// normalized coords (origin bottom-left); we convert to top-left pixel space,
// which is the space calibration points were tapped in.

import Vision
import CoreML
import CoreVideo
import CoreGraphics
import QuartzCore

// MARK: - Output types

struct TrackedPlayer {
    let id: Int
    let boxPx: CGRect          // top-left pixel coords
    let footPx: CGPoint        // bbox bottom-center
    let courtPos: CGPoint      // smoothed court meters
    let confidence: Float
}

struct FrameResult {
    var players: [TrackedPlayer] = []
    var ballPx: CGPoint?
    var ballCourt: CGPoint?
    var latencyMs: Double = 0
}

// MARK: - Detector

final class Detector {
    private let playerModel: VNCoreMLModel
    private let ballModel: VNCoreMLModel
    private let playerRequest: VNCoreMLRequest
    private let ballRequest: VNCoreMLRequest

    private let playerTracker = PlayerTracker()
    private let ballTracker = BallTrackerSwift()

    var calibration: Calibration?

    init?(calibration: Calibration?) {
        self.calibration = calibration
        let config = MLModelConfiguration()
        config.computeUnits = .all   // Neural Engine + GPU + CPU

        guard let pURL = Bundle.main.url(forResource: "PlayerDetector", withExtension: "mlmodelc"),
              let bURL = Bundle.main.url(forResource: "BallDetector", withExtension: "mlmodelc"),
              let pModel = try? MLModel(contentsOf: pURL, configuration: config),
              let bModel = try? MLModel(contentsOf: bURL, configuration: config),
              let pVN = try? VNCoreMLModel(for: pModel),
              let bVN = try? VNCoreMLModel(for: bModel) else {
            return nil
        }
        playerModel = pVN
        ballModel = bVN
        playerRequest = VNCoreMLRequest(model: playerModel)
        ballRequest = VNCoreMLRequest(model: ballModel)
        // Aspect-preserving letterbox (matches the Python pipeline); Vision maps
        // boxes back to original-image coordinates for us.
        playerRequest.imageCropAndScaleOption = .scaleFit
        ballRequest.imageCropAndScaleOption = .scaleFit
    }

    /// Run both models on one frame and return tracked players + chosen ball.
    func process(_ pixelBuffer: CVPixelBuffer) -> FrameResult {
        let t0 = CACurrentMediaTime()
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([playerRequest, ballRequest])

        // --- Players ---
        var playerDets: [PlayerTracker.Detection] = []
        for obs in (playerRequest.results as? [VNRecognizedObjectObservation]) ?? [] {
            guard obs.labels.first?.identifier == "person" else { continue }
            let b = obs.boundingBox
            let box = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            let foot = CGPoint(x: b.midX * w, y: (1 - b.minY) * h)   // bottom-center
            let court = calibration?.toCourt(foot) ?? .zero
            playerDets.append(.init(box: box, foot: foot, confidence: obs.confidence, court: court))
        }
        let players = playerTracker.update(playerDets)

        // --- Ball ---
        var ballCandidates: [BallTrackerSwift.Candidate] = []
        for obs in (ballRequest.results as? [VNRecognizedObjectObservation]) ?? [] {
            let b = obs.boundingBox
            let center = CGPoint(x: b.midX * w, y: (1 - b.midY) * h)
            let court = calibration?.toCourt(center)
            ballCandidates.append(.init(px: center, score: obs.confidence, court: court))
        }
        let ballPx = ballTracker.select(from: ballCandidates, frameWidth: w)
        let ballCourt = ballPx.flatMap { calibration?.toCourt($0) }

        var result = FrameResult(players: players, ballPx: ballPx, ballCourt: ballCourt)
        result.latencyMs = (CACurrentMediaTime() - t0) * 1000
        return result
    }
}

// MARK: - Player tracker (lightweight IoU + 5-frame court smoothing)

final class PlayerTracker {
    struct Detection { let box: CGRect; let foot: CGPoint; let confidence: Float; let court: CGPoint }

    private struct Track {
        var id: Int
        var box: CGRect
        var foot: CGPoint
        var confidence: Float
        var courtHistory: [CGPoint]   // last N court positions for smoothing
        var age: Int                  // frames since last match
    }

    private var tracks: [Track] = []
    private var nextID = 1
    private let maxAge = 15           // drop a track after this many unmatched frames
    private let smoothing = 5         // 5-frame moving average, matches detect.py
    private let iouGate: CGFloat = 0.2

    func update(_ detections: [Detection]) -> [TrackedPlayer] {
        // Greedy IoU matching: strongest overlaps first.
        var unmatchedDet = Array(detections.indices)
        var matched: [(trackIdx: Int, detIdx: Int)] = []
        var usedTracks = Set<Int>()

        var pairs: [(iou: CGFloat, t: Int, d: Int)] = []
        for (t, track) in tracks.enumerated() {
            for d in detections.indices {
                let i = iou(track.box, detections[d].box)
                if i >= iouGate { pairs.append((i, t, d)) }
            }
        }
        pairs.sort { $0.iou > $1.iou }
        var usedDet = Set<Int>()
        for p in pairs where !usedTracks.contains(p.t) && !usedDet.contains(p.d) {
            usedTracks.insert(p.t); usedDet.insert(p.d)
            matched.append((p.t, p.d))
        }
        unmatchedDet.removeAll { usedDet.contains($0) }

        // Update matched tracks.
        for (t, d) in matched {
            let det = detections[d]
            tracks[t].box = det.box
            tracks[t].foot = det.foot
            tracks[t].confidence = det.confidence
            tracks[t].courtHistory.append(det.court)
            if tracks[t].courtHistory.count > smoothing { tracks[t].courtHistory.removeFirst() }
            tracks[t].age = 0
        }
        // Age / drop unmatched tracks.
        for t in tracks.indices where !usedTracks.contains(t) { tracks[t].age += 1 }
        tracks.removeAll { $0.age > maxAge }
        // Spawn new tracks.
        for d in unmatchedDet {
            let det = detections[d]
            tracks.append(.init(id: nextID, box: det.box, foot: det.foot,
                                confidence: det.confidence, courtHistory: [det.court], age: 0))
            nextID += 1
        }

        // Emit only tracks matched this frame (age == 0).
        return tracks.filter { $0.age == 0 }.map { t in
            let hist = t.courtHistory
            let mean = CGPoint(x: hist.reduce(0) { $0 + $1.x } / CGFloat(hist.count),
                               y: hist.reduce(0) { $0 + $1.y } / CGFloat(hist.count))
            return TrackedPlayer(id: t.id, boxPx: t.box, footPx: t.foot,
                                 courtPos: mean, confidence: t.confidence)
        }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}

// MARK: - Ball tracker (trajectory-consistent selection + court bounds)

final class BallTrackerSwift {
    struct Candidate { let px: CGPoint; let score: Float; let court: CGPoint? }

    // Ports the tuned constants from ball_tracker.py.
    private let trajectoryGateFrac: CGFloat = 0.12
    private let maxMisses = 4
    private let recentCap = 4
    private let courtXMargin: CGFloat = 3.0
    private let courtYMargin: CGFloat = 5.0

    private var recent: [CGPoint] = []   // recent chosen positions
    private var misses = 0

    /// Among this frame's candidates, reject clearly off-court ones (if a
    /// homography is available), then prefer the one nearest the position
    /// predicted from recent motion -- so a static distractor off the moving
    /// ball's path is skipped even when it briefly outscores the real ball.
    func select(from candidates: [Candidate], frameWidth: CGFloat) -> CGPoint? {
        let survivors = candidates.filter { c in
            guard let court = c.court else { return true }   // no calibration -> keep all
            if abs(court.x) > CGFloat(Court.halfWidthM) + courtXMargin { return false }
            if court.y > CGFloat(Court.lengthM) + courtYMargin || court.y < -courtYMargin { return false }
            return true
        }
        guard !survivors.isEmpty else {
            misses += 1
            if misses > maxMisses { recent = [] }   // stale track -> re-acquire fresh
            return nil
        }

        let chosen = selectByTrajectory(survivors, frameWidth: frameWidth)
        misses = 0
        recent.append(chosen)
        if recent.count > recentCap { recent.removeFirst() }
        return chosen
    }

    private func selectByTrajectory(_ survivors: [Candidate], frameWidth: CGFloat) -> CGPoint {
        let gate = trajectoryGateFrac * frameWidth
        let predicted: CGPoint?
        if recent.count >= 2 {
            let p0 = recent[recent.count - 2], p1 = recent[recent.count - 1]
            predicted = CGPoint(x: p1.x + (p1.x - p0.x), y: p1.y + (p1.y - p0.y)) // constant velocity
        } else if recent.count == 1 {
            predicted = recent[0]
        } else {
            predicted = nil
        }

        if let pred = predicted {
            let near = survivors.filter { hypot($0.px.x - pred.x, $0.px.y - pred.y) <= gate }
            if let best = near.max(by: { $0.score < $1.score }) { return best.px }
        }
        // No recent track or nothing consistent: re-acquire by confidence.
        return survivors.max(by: { $0.score < $1.score })!.px
    }
}
