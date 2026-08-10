// Tactics.swift
//
// The tactical layer - Swift port of `shot_cone`, `find_opponent` and
// `bisector_offset` from the prototype's `src/detect.py`. Pure geometry in
// court metres; no drawing, no Vision.
//
// The idea is Cochet's "theory of angles": from where you strike, there is a
// range of legal shot directions, and the BISECTOR of that range is where your
// opponent should stand to cover it. How far they actually are off that line is
// the product's signal - the thing the buzzer fires on.
//
// "Opponent" here means the STRIKER's opponent - the far player - and that is
// the person the app coaches: you mount the phone behind your opponent's
// baseline, they strike near-side, and YOU are the far player being told you're
// out of position. The wearer is measured, not the striker.

import Foundation
import CoreGraphics

/// Metres off the bisector that counts as out of position - the buzz trigger.
/// Verified against real play: a pro sits 0.1-1.2m off (i.e. never trips it);
/// the genuinely-out-of-position moment on the test footage measured 2.6-2.8m.
let outOfPositionM: Double = 2.0

enum Tactics {

    /// Realistic in-court shot cone from a contact at `apex`. Returns the two
    /// extreme landing corners and the bisector's end point, in court metres.
    ///
    /// The sharpest angle a player can realistically hit is NOT to the net
    /// corner - the ball has to clear the net and come down - so the tightest
    /// realistic landing is the opponent's SERVICE-line/sideline corner, and the
    /// deepest is the baseline corner. Taking min/max BEARING over those four
    /// corners makes the cone narrow and swing correctly when the striker is
    /// pulled wide, with no special cases.
    static func shotCone(apex: CGPoint) -> (left: CGPoint, right: CGPoint, bisector: CGPoint) {
        let xl = -Court.halfWidthM, xr = Court.halfWidthM
        let yNear = Court.farServiceLineY, yFar = Court.lengthM
        let corners = [CGPoint(x: xl, y: yNear), CGPoint(x: xr, y: yNear),
                       CGPoint(x: xl, y: yFar), CGPoint(x: xr, y: yFar)]
        let byBearing = corners
            .map { (bearing: atan2($0.x - apex.x, $0.y - apex.y), point: $0) }
            .sorted { $0.bearing < $1.bearing }
        guard let left = byBearing.first, let right = byBearing.last else {
            return (apex, apex, apex)
        }
        let bis = (left.bearing + right.bearing) / 2.0
        var bx = apex.x + tan(bis) * (yFar - apex.y)
        bx = max(xl, min(xr, bx))                 // keep the endpoint in-court
        return (left.point, right.point, CGPoint(x: bx, y: yFar))
    }

    /// Perpendicular distance in metres from `opponent` to the bisector line
    /// (apex -> bisector end), plus the foot of that perpendicular. This is how
    /// far off the ideal recovery axis they are - the tactical positioning error.
    static func bisectorOffset(opponent: CGPoint, apex: CGPoint,
                               bisector: CGPoint) -> (metres: Double, foot: CGPoint) {
        let dx = bisector.x - apex.x, dy = bisector.y - apex.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else {
            return (hypot(opponent.x - apex.x, opponent.y - apex.y), apex)
        }
        let t = ((opponent.x - apex.x) * dx + (opponent.y - apex.y) * dy) / l2
        let foot = CGPoint(x: apex.x + t * dx, y: apex.y + t * dy)
        return (hypot(opponent.x - foot.x, opponent.y - foot.y), foot)
    }

    struct Opponent {
        let id: Int
        let court: CGPoint
        let footPx: CGPoint
    }

    /// The striker's opponent: the ON-COURT player on the FAR side (court
    /// Y > net). The lateral filter is what excludes ball kids and line judges -
    /// they stand well outside the sidelines - while the Y bound is generous
    /// because players stand BEHIND their baseline. Biggest box wins, which
    /// picks the real player over a distant bystander.
    static func findOpponent(courtPositions: [Int: CGPoint], boxes: [ContactBox],
                             strikerID: Int?) -> Opponent? {
        var best: (area: Double, opp: Opponent)?
        for (id, pos) in courtPositions {
            if let s = strikerID, id == s { continue }
            guard pos.y > Court.netY,
                  abs(pos.x) <= Court.halfWidthM + 1.0,
                  pos.y <= Court.lengthM + 3.5 else { continue }
            guard let box = boxes.first(where: { $0.id == id }) else { continue }
            let area = Double(box.rect.width * box.rect.height)
            if best == nil || area > best!.area {
                let foot = CGPoint(x: box.rect.midX, y: box.rect.maxY)   // the red foot dot
                best = (area, Opponent(id: id, court: pos, footPx: foot))
            }
        }
        return best?.opp
    }
}
