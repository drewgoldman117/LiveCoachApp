// Contact.swift
//
// Ball-racket contact detection - Swift port of the prototype's `src/contact.py`.
// Pure arithmetic: no Vision, no CoreGraphics drawing, no camera. Same shape as
// the Python module, deliberately, so the two can be compared line by line.
//
// A racket contact is a sharp REVERSAL of the ball's image-space velocity (it
// approached the striker, now it recedes). Reversal alone is high-recall and
// low-precision - it also fires on court bounces and detector noise - so
// precision comes from a stack of gates, EVERY ONE of which exists because it
// killed a specific observed false positive. Do not "simplify" them away
// without re-reading the rationale in the Python repo's CLAUDE.md
// ("Contact detection ... Bugs found and how they're fixed").
//
// Why pixel space and not court meters: the homography assumes a point on the
// court plane, but the ball is ABOVE the plane in flight, so its mapped court
// position is wrong mid-flight. Trajectory shape and "is the ball at the
// player" are both honest in the image. Player FEET are on the ground, so their
// court positions stay valid and are used for the court-region gates.

import Foundation
import CoreGraphics

struct ContactEvent {
    var frame: Int
    var strikerID: Int?
    var ballPx: CGPoint
    var score: Double
}

/// (trackID, box) for one player on one frame.
struct ContactBox {
    let id: Int
    let rect: CGRect
}

enum ContactTuning {
    /// Interpolate ball gaps up to this many missing frames. The ball routinely
    /// vanishes (blur/occlusion) AT contact, so a short gap straddling the
    /// reversal is expected; longer gaps are left missing rather than invented.
    static let gapInterpMax = 5
    /// Frames averaged each side when measuring incoming vs outgoing direction.
    /// Widened 3 -> 7 in the prototype to see the reversal through the ball's
    /// DWELL on a low running pickup (it nearly stops near the ground for ~10
    /// frames); that also recovered several far-player contacts.
    static let velWindow = 7
    /// Below this image speed (px/frame) it's detector jitter, not a struck
    /// ball. Resolution-dependent - first knob to tune on new footage.
    static let minSpeedPx = 4.0
    /// Cosine ceiling between mean incoming and outgoing velocity (~107 deg).
    static let reversalCosMax = -0.3
    /// THE primary precision gate: the ball must be essentially AT the body,
    /// measured in box HEIGHTS so it generalises across perspective. Small
    /// (~0.2) because the person box already grows to include an extended
    /// arm/racket. Verified: real contacts <= 0.18 box-heights, a ball merely
    /// approaching 0.25-0.34, a mid-court bounce 0.75.
    static let reachFrac = 0.2
    static let reachMinPx = 15.0
    /// The reversal and the player's closest approach can be a few frames apart
    /// on a lunge (racket ahead of the body box), so proximity scans a window.
    static let proximityTolFrames = 8
    /// Hit-vs-bounce: a bounce sits at the feet line, a contact is up at
    /// racket/body height. Approximated as height above the box bottom. Kept low
    /// so genuine half-volleys still pass.
    static let minBallAboveFeetFrac = 0.15
    /// "There-and-back excursion": the ball label jumps onto a player's
    /// arm/wristband for a few frames then snaps back, faking a reversal right
    /// at a player. A real ball cannot teleport away and instantly return.
    static let excursionSkipFrames = 8
    static let excursionJumpPx = 300.0
    static let excursionReturnPx = 200.0
    /// NOISE FLOOR only - proximity is the precision gate. A high score
    /// threshold wrongly dropped genuine SOFT contacts (a touch volley scores
    /// ~7 yet is a real strike).
    static let minContactScore = 3.0
    /// The struck ball must be near the striker in court DEPTH, not merely
    /// pixel-adjacent: a tall baseline box overlaps the pixel row of a ball up
    /// near the net. Generous because the airborne ball's mapped Y is biased.
    static let maxDepthGapM = 7.0
    /// Refractory gap. One stroke fires a reversal on the backswing AND at the
    /// strike ~0.5s apart; rec-level rally hits are >0.7s apart.
    static let minGapS = 0.7
}

enum ContactDetector {

    // MARK: - Trajectory helpers

    static func interpolateGaps(_ ball: [CGPoint?], gapMax: Int) -> [CGPoint?] {
        var out = ball
        let valid = ball.indices.filter { ball[$0] != nil }
        for (a, b) in zip(valid, valid.dropFirst()) {
            let gap = b - a
            guard gap > 1, gap <= gapMax + 1, let pa = ball[a], let pb = ball[b] else { continue }
            for j in (a + 1)..<b {
                let t = CGFloat(j - a) / CGFloat(gap)
                out[j] = CGPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t)
            }
        }
        return out
    }

    static func velocities(_ pos: [CGPoint?]) -> [CGPoint?] {
        var v = [CGPoint?](repeating: nil, count: pos.count)
        for f in 1..<max(1, pos.count) {
            if let a = pos[f], let b = pos[f - 1] {
                v[f] = CGPoint(x: a.x - b.x, y: a.y - b.y)
            }
        }
        return v
    }

    static func meanVec(_ v: [CGPoint?], _ lo: Int, _ hi: Int) -> CGPoint? {
        var sx = 0.0, sy = 0.0, n = 0
        for k in max(lo, 0)..<min(hi, v.count) {
            if let p = v[k] { sx += p.x; sy += p.y; n += 1 }
        }
        guard n > 0 else { return nil }
        return CGPoint(x: sx / Double(n), y: sy / Double(n))
    }

    /// Point-to-box distance (0 inside the box).
    static func distance(_ p: CGPoint, to r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// The player within racket-reach of `pt`, nearest first. Reach scales with
    /// box height, which is what makes one fraction work across perspective.
    static func nearestPlayer(_ pt: CGPoint, _ boxes: [ContactBox]) -> ContactBox? {
        var best: ContactBox?
        var bestD = Double.infinity
        for b in boxes {
            let d = distance(pt, to: b.rect)
            let reach = max(ContactTuning.reachMinPx, ContactTuning.reachFrac * b.rect.height)
            if d <= reach && d < bestD { best = b; bestD = d }
        }
        return best
    }

    struct Meeting {
        let box: ContactBox
        let ball: CGPoint
        let frame: Int
    }

    /// Closest ball-meets-player over [f-tol, f+tol], each frame using its OWN
    /// ball position and boxes. The slack absorbs the reversal-vs-arrival offset
    /// on a lunge; a true bounce out in the court has nobody arriving at all.
    static func nearestPlayerWindowed(_ pos: [CGPoint?], _ boxes: [[ContactBox]],
                                      _ f: Int, tol: Int) -> Meeting? {
        var best: Meeting?
        var bestD = Double.infinity
        for k in max(0, f - tol)...min(pos.count - 1, f + tol) {
            guard k < boxes.count, let p = pos[k], let hit = nearestPlayer(p, boxes[k]) else { continue }
            guard hit.rect.height > 0 else { continue }
            let d = distance(p, to: hit.rect) / hit.rect.height   // box-heights: comparable across frames
            if d < bestD { best = Meeting(box: hit, ball: p, frame: k); bestD = d }
        }
        return best
    }

    /// First real detection at least `skip` frames away - i.e. on the real
    /// trajectory, outside a short excursion around f.
    static func anchor(_ ball: [CGPoint?], _ f: Int, _ direction: Int, _ skip: Int) -> CGPoint? {
        for d in skip..<(skip + 25) {
            let k = f + direction * d
            if k >= 0, k < ball.count, let p = ball[k] { return p }
        }
        return nil
    }

    /// A jump-away-and-return spike: the real trajectory on BOTH sides is far
    /// from this point but close to itself, meaning the ball left and came back
    /// rather than travelling on. A real contact sends the ball away (anchors
    /// far apart); a camera cut jumps one-way (also far apart) - neither trips.
    static func isReturnExcursion(_ ball: [CGPoint?], _ f: Int, _ ballAt: CGPoint) -> Bool {
        guard let before = anchor(ball, f, -1, ContactTuning.excursionSkipFrames),
              let after = anchor(ball, f, 1, ContactTuning.excursionSkipFrames) else { return false }
        let db = hypot(before.x - ballAt.x, before.y - ballAt.y)
        let da = hypot(after.x - ballAt.x, after.y - ballAt.y)
        let dba = hypot(after.x - before.x, after.y - before.y)
        return db > ContactTuning.excursionJumpPx
            && da > ContactTuning.excursionJumpPx
            && dba < ContactTuning.excursionReturnPx
    }

    /// Null out arm/body latch spikes BEFORE interpolation - otherwise the spike
    /// contaminates the interpolated trajectory on either side too, faking a
    /// reversal at the excursion's edge rather than only at its center.
    static func despikeExcursions(_ ball: [CGPoint?]) -> [CGPoint?] {
        var out = ball
        for f in ball.indices where ball[f] != nil {
            if isReturnExcursion(ball, f, ball[f]!) { out[f] = nil }
        }
        return out
    }

    static func ballNear(_ pos: [CGPoint?], _ f: Int, window: Int) -> CGPoint? {
        if let p = pos[f] { return p }
        for d in 1...max(1, window) {
            for k in [f - d, f + d] where k >= 0 && k < pos.count {
                if let p = pos[k] { return p }
            }
        }
        return nil
    }

    // MARK: - Main entry point

    /// `ballPositions[f]` and `playerBoxes[f]` share one frame numbering.
    /// `playerCourt[f][id]` is the smoothed court position of each player.
    static func detectContacts(ballPositions: [CGPoint?],
                               playerBoxes: [[ContactBox]],
                               fps: Double,
                               playerCourt: [[Int: CGPoint]]? = nil,
                               homography: Homography? = nil,
                               nearSideOnly: Bool = true,
                               backcourtOnly: Bool = true) -> [ContactEvent] {
        let n = ballPositions.count
        guard n > 0 else { return [] }

        let clean = despikeExcursions(ballPositions)
        let pos = interpolateGaps(clean, gapMax: ContactTuning.gapInterpMax)
        let vel = velocities(pos)

        var candidates: [ContactEvent] = []
        for f in 0..<n {
            // 1) candidate reversal: opposed mean velocities, real speed both sides
            guard let pre = meanVec(vel, f - ContactTuning.velWindow + 1, f + 1),
                  let post = meanVec(vel, f + 1, f + 1 + ContactTuning.velWindow) else { continue }
            let spPre = hypot(pre.x, pre.y), spPost = hypot(post.x, post.y)
            if spPre < ContactTuning.minSpeedPx || spPost < ContactTuning.minSpeedPx { continue }
            let cos = (pre.x * post.x + pre.y * post.y) / (spPre * spPost)
            if cos > ContactTuning.reversalCosMax { continue }
            guard ballNear(pos, f, window: ContactTuning.velWindow) != nil else { continue }

            // 2) proximity gate + striker identity (temporal-tolerant)
            guard let meet = nearestPlayerWindowed(pos, playerBoxes, f,
                                                   tol: ContactTuning.proximityTolFrames) else { continue }

            // 2b) court-region gates. near-side only (a far-side ball is a few
            //     px and mostly undetected) and backcourt only (the shot cone is
            //     a baseline concept; net play degenerates it).
            var court: CGPoint?
            if let playerCourt, meet.frame < playerCourt.count {
                court = playerCourt[meet.frame][meet.box.id]
                if let c = court {
                    let limit = backcourtOnly ? Court.nearServiceLineY
                              : (nearSideOnly ? Court.netY : Double.infinity)
                    if c.y >= limit { continue }
                }
            }

            // 2c) attribution sanity in court DEPTH
            if let h = homography, let c = court {
                let mapped = h.apply(meet.ball)
                if abs(mapped.y - c.y) > ContactTuning.maxDepthGapM { continue }
            }

            // 3) hit-vs-bounce height gate, evaluated at the meeting
            let boxH = meet.box.rect.height
            if meet.ball.y > meet.box.rect.maxY - ContactTuning.minBallAboveFeetFrac * boxH { continue }

            // sharper reversal + faster ball => stronger score
            let score = (1.0 - cos) / 2.0 * min(spPre, spPost)
            if score < ContactTuning.minContactScore { continue }
            candidates.append(ContactEvent(frame: f, strikerID: meet.box.id,
                                           ballPx: meet.ball, score: score))
        }

        // 4) debounce: score-ranked non-maximum suppression, so a burst of
        //    adjacent reversal frames collapses to its strongest frame.
        let minGap = max(1, Int((ContactTuning.minGapS * fps).rounded()))
        var accepted: [ContactEvent] = []
        for cand in candidates.sorted(by: { $0.score > $1.score }) {
            if accepted.allSatisfy({ abs(cand.frame - $0.frame) > minGap }) {
                accepted.append(cand)
            }
        }
        return accepted.sorted { $0.frame < $1.frame }
    }
}

// MARK: - Causal / live wrapper

/// Streaming contact detection. `detectContacts` is offline - it needs frames
/// BOTH sides of a strike - so this buffers a trailing window, re-runs the
/// (cheap, pure-arithmetic) detector each frame, and COMMITS a contact only once
/// enough future frames exist for the result to be stable.
///
/// The lag is the IRREDUCIBLE lookahead only - `max(velWindow, excursionSkip)+3`
/// ~= 11 frames - NOT the debounce gap. So **0.18s at 60fps, 0.37s at 30fps**,
/// which is why 60fps capture matters for more than ball detection.
final class LiveContactDetector {
    private(set) var fps: Double
    private let window: Int
    private let lag: Int
    private var minGap: Int
    var homography: Homography?

    /// Re-base the detector on the rate frames ACTUALLY arrive at.
    ///
    /// The camera captures 60fps but `AVCaptureVideoDataOutput` has
    /// `alwaysDiscardsLateVideoFrames = true`, so the pipeline sees only what it
    /// can keep up with - maybe 30. Everything time-based here is measured in
    /// FRAMES, so believing "60" while receiving 30 doubles the debounce in real
    /// seconds (0.7s becomes 1.4s) and merges genuine consecutive strokes into
    /// one. Feed this the measured rate.
    func setFrameRate(_ measured: Double) {
        guard measured > 5, abs(measured - fps) > 2 else { return }
        fps = measured
        minGap = max(1, Int((ContactTuning.minGapS * measured).rounded()))
    }

    private var ball: [CGPoint?] = []
    private var boxes: [[ContactBox]] = []
    private var court: [[Int: CGPoint]] = []
    private var n = 0
    private var emitted: [Int] = []

    /// Everything a caller needs about a committed contact, captured AT THE
    /// CONTACT FRAME. See `update` for why that matters.
    struct Committed {
        let event: ContactEvent
        let apexCourt: CGPoint?
        let courtAt: [Int: CGPoint]
        let boxesAt: [ContactBox]
    }

    init(fps: Double, homography: Homography?, windowSeconds: Double = 3.0) {
        self.fps = fps
        self.homography = homography
        self.window = max(30, Int((windowSeconds * fps).rounded()))
        self.lag = max(ContactTuning.velWindow, ContactTuning.excursionSkipFrames) + 3
        self.minGap = max(1, Int((ContactTuning.minGapS * fps).rounded()))
    }

    /// Feed one frame; returns contacts newly confirmed this frame (usually none).
    func update(ballPx: CGPoint?, boxes boxesNow: [ContactBox],
                court courtNow: [Int: CGPoint]) -> [Committed] {
        ball.append(ballPx)
        boxes.append(boxesNow)
        court.append(courtNow)
        let f = n
        n += 1

        let lo = max(0, f - window + 1)
        let contacts = ContactDetector.detectContacts(
            ballPositions: Array(ball[lo...f]),
            playerBoxes: Array(boxes[lo...f]),
            fps: fps,
            playerCourt: Array(court[lo...f]),
            homography: homography)

        var newly: [Committed] = []
        for c in contacts {
            let af = lo + c.frame                       // window-relative -> absolute
            if af > f - lag { continue }                // not enough lookahead yet
            if emitted.contains(where: { abs(af - $0) < minGap }) { continue }
            emitted.append(af)
            var event = c
            event.frame = af
            // Hand back the world AS IT WAS AT THE CONTACT FRAME. A contact is
            // confirmed ~11 frames after it happened, so a caller using its own
            // current frame measures everyone a fifth of a second late - and by
            // an amount that CHANGES WITH FRAME RATE. That made the
            // opponent-offset metric frame-rate dependent in the prototype (the
            // same strike scored 2.1m at 60fps and 1.6m at 30fps; one fires the
            // 2.0m alert and the other doesn't). The tactical claim is about the
            // moment of the strike, so measure there.
            let courtAt = af < court.count ? court[af] : [:]
            let boxesAt = af < boxes.count ? boxes[af] : []
            newly.append(Committed(event: event,
                                   apexCourt: c.strikerID.flatMap { courtAt[$0] },
                                   courtAt: courtAt,
                                   boxesAt: boxesAt))
        }

        // Trim the buffers so a long session doesn't grow without bound. Keep
        // well beyond the window so absolute indices stay valid for the lag.
        return newly
    }
}
