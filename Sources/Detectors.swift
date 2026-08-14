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

    /// The region the BALL model looks at, in Vision's normalized lower-left
    /// coordinates. Full frame until a court map exists; then the court plus
    /// margins.
    ///
    /// This is a RESOLUTION lever, not a cleanup one. The model has a fixed
    /// 1280x1280 input, so a full 1920x1440 buffer is letterboxed down 1.5x
    /// and a ball the model would resolve at 9px arrives at 6px - which is the
    /// difference between this phone and the recorded clips the model is known
    /// to work on. Cropping to the court hands that resolution back exactly
    /// where the ball can be. Margins: the doubles alleys plus a meter wide,
    /// three meters behind the near baseline (where the server stands), and
    /// 40% of the court's height of headroom above the far baseline, because
    /// the ball spends much of a rally in the air above the court. Players are
    /// NOT cropped - the near player's feet can sit below any court crop.
    private func ballROI(frameWidth w: CGFloat, frameHeight h: CGFloat) -> CGRect {
        guard let cal = calibration else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for x in [-6.5, 6.5] {
            for y in [-3.0, Court.lengthM] {
                let p = cal.toImage(CGPoint(x: x, y: y))
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX < maxX, minY < maxY else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        minY -= 0.4 * (maxY - minY)                      // headroom for the ball in flight
        let x0 = max(0, minX / w), x1 = min(1, maxX / w)
        let yTop = max(0, minY / h), yBot = min(1, maxY / h)
        // Vision: lower-left origin, so image rows flip.
        return CGRect(x: x0, y: 1 - yBot, width: x1 - x0, height: yBot - yTop)
    }

    /// Run both models on one frame and return tracked players + chosen ball.
    func process(_ pixelBuffer: CVPixelBuffer) -> FrameResult {
        let t0 = CACurrentMediaTime()
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let roi = ballROI(frameWidth: w, frameHeight: h)
        ballRequest.regionOfInterest = roi

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
            // With a regionOfInterest set, boundingBox is normalized to the
            // ROI, not the frame - map back out before leaving Vision space.
            let b = obs.boundingBox
            let nx = roi.minX + b.midX * roi.width
            let ny = roi.minY + b.midY * roi.height          // lower-left origin
            let center = CGPoint(x: nx * w, y: (1 - ny) * h)
            let court = calibration?.toCourt(center)
            ballCandidates.append(.init(px: center, score: obs.confidence, court: court,
                                        size: max(b.width * roi.width * w,
                                                  b.height * roi.height * h)))
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
    struct Candidate {
        let px: CGPoint
        let score: Float
        let court: CGPoint?
        /// Apparent diameter in buffer pixels - what the crawl rule divides by.
        var size: CGFloat = 0
    }

    // Ports the tuned constants from ball_tracker.py.
    private let trajectoryGateFrac: CGFloat = 0.12
    private let maxMisses = 4
    private let recentCap = 4
    private let courtXMargin: CGFloat = 3.0
    private let courtYMargin: CGFloat = 5.0

    // A REAL BALL MOVES. Two rules from ball_tracker.py enforce that, and they
    // are complementary - neither catches the other's case:
    //
    //  * STATIC: a position that holds still (within staticRadiusFrac of frame
    //    width) for staticFrames consecutive picks is not the ball in play -
    //    it is a ball lying on the apron, a logo, a shoe. It is blacklisted and
    //    candidates near it are skipped. TTL'd rather than permanent, because
    //    an amateur court's distractors are balls that later get picked up and
    //    hit, unlike a broadcast's sponsor boards.
    //  * CRAWL: a ball merely ROLLING never trips the static rule (it travels
    //    beyond the radius) but is just as dead, and following it means missing
    //    the ball the next point is played with. Speed in PIXELS is the wrong
    //    test - perspective makes a genuinely fast far-court ball move only a
    //    few pixels per frame - so the test is displacement per frame relative
    //    to the ball's OWN apparent diameter, which is depth-invariant. A
    //    struck ball covers multiples of its width per frame; a rolling one a
    //    small fraction (< crawlStepFrac) for crawlFrames in a row.
    //
    // Pixel constants are fractions of frame width because this buffer (1920)
    // is not the resolution they were tuned at (1280).
    private let staticRadiusFrac: CGFloat = 15.0 / 1280.0
    private let staticFrames = 30
    private let blacklistExcludeFrac: CGFloat = 120.0 / 1280.0
    private let blacklistTTLFrames = 3600
    private let crawlStepFrac: CGFloat = 0.35
    private let crawlFrames = 45

    private var recent: [CGPoint] = []   // recent chosen positions
    private var misses = 0
    private var frameNo = 0
    private var blacklist: [(pos: CGPoint, frame: Int)] = []
    private var watchPos: CGPoint?
    private var watchCount = 0
    private var crawl = 0

    /// Among this frame's candidates, reject clearly off-court ones (if a
    /// homography is available) and ones near a blacklisted static distractor,
    /// prefer the one nearest the position predicted from recent motion, then
    /// apply the two is-it-actually-moving rules above to the winner.
    func select(from candidates: [Candidate], frameWidth: CGFloat) -> CGPoint? {
        frameNo += 1
        blacklist.removeAll { frameNo - $0.frame > blacklistTTLFrames }

        let excludeR = blacklistExcludeFrac * frameWidth
        let survivors = candidates.filter { c in
            if blacklist.contains(where: { hypot(c.px.x - $0.pos.x, c.px.y - $0.pos.y) < excludeR }) {
                return false
            }
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
        let chosenSize = survivors.first(where: { $0.px == chosen })?.size ?? 0

        // CRAWL: rolling = dead. Checked before the track is extended, so a
        // blacklisted roller doesn't seed the next frame's prediction.
        if chosenSize > 0, let last = recent.last {
            let step = hypot(chosen.x - last.x, chosen.y - last.y) / chosenSize
            crawl = step < crawlStepFrac ? crawl + 1 : 0
            if crawl >= crawlFrames {
                blacklist.append((chosen, frameNo))
                crawl = 0
                recent = []                  // re-acquire whatever is actually in play
                return nil
            }
        }

        misses = 0
        recent.append(chosen)
        if recent.count > recentCap { recent.removeFirst() }

        // STATIC: the same spot picked staticFrames times in a row is not the
        // ball in play, whatever its confidence.
        let staticR = staticRadiusFrac * frameWidth
        if let wp = watchPos, hypot(chosen.x - wp.x, chosen.y - wp.y) < staticR {
            watchCount += 1
        } else {
            watchPos = chosen
            watchCount = 1
        }
        if watchCount >= staticFrames {
            blacklist.append((chosen, frameNo))
            watchPos = nil
            watchCount = 0
            recent = []                      // drop the blacklisted position from the track
            return nil
        }
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
