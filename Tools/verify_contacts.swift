// Verification harness: run the APP's ported contact/tactics code over the same
// detection cache the Python prototype uses, and print the contacts + opponent
// offsets so the two implementations can be compared directly.
//
// Not part of the app target - compiled standalone with swiftc.

import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: verify <dets.json> <calibration.json> [fps]")
    exit(2)
}
let fps = args.count > 3 ? Double(args[3]) ?? 30 : 30

struct Dets: Decodable {
    let ball: [[Double]?]
    let boxes: [[[Double]]]
    let smoothed: [[String: [Double]]]
}
// calibration/*.json stores the 3x3 as nested rows; the app's Homography takes
// it flat row-major (Calibration.swift does the same flattening).
struct CalJSON: Decodable {
    let homography: [[Double]]
    let homography_inv: [[Double]]
}

let dets = try JSONDecoder().decode(Dets.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let cal = try JSONDecoder().decode(CalJSON.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))

let ball: [CGPoint?] = dets.ball.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
let boxes: [[ContactBox]] = dets.boxes.map { frame in
    frame.map { ContactBox(id: Int($0[0]),
                           rect: CGRect(x: $0[1], y: $0[2],
                                        width: $0[3] - $0[1], height: $0[4] - $0[2])) }
}
let court: [[Int: CGPoint]] = dets.smoothed.map { d in
    var out: [Int: CGPoint] = [:]
    for (k, v) in d { out[Int(k) ?? -1] = CGPoint(x: v[0], y: v[1]) }
    return out
}

let H = Homography(cal.homography.flatMap { $0 })

print("frames: \(ball.count), fps \(fps)")

// --- offline detector (matches Python detect_contacts) ---
let contacts = ContactDetector.detectContacts(ballPositions: ball, playerBoxes: boxes,
                                              fps: fps, playerCourt: court, homography: H)
print("OFFLINE contacts: \(contacts.count)")
for c in contacts {
    var line = String(format: "  frame %d  striker #%d  score=%.1f",
                      c.frame, c.strikerID ?? -1, c.score)
    if let apex = court[c.frame][c.strikerID ?? -1] {
        let cone = Tactics.shotCone(apex: apex)
        if let opp = Tactics.findOpponent(courtPositions: court[c.frame],
                                          boxes: boxes[c.frame], strikerID: c.strikerID) {
            let off = Tactics.bisectorOffset(opponent: opp.court, apex: apex, bisector: cone.bisector)
            line += String(format: "  opponent %.1fm off%@", off.metres,
                           off.metres > outOfPositionM ? "  OUT OF POSITION" : "")
        }
    }
    print(line)
}

// --- causal detector (what the app actually runs) ---
let live = LiveContactDetector(fps: fps, homography: H)
var liveHits: [(Int, Double)] = []
for f in 0..<ball.count {
    for hit in live.update(ballPx: ball[f], boxes: boxes[f], court: court[f]) {
        var metres = -1.0
        if let apex = hit.apexCourt {
            let cone = Tactics.shotCone(apex: apex)
            if let opp = Tactics.findOpponent(courtPositions: hit.courtAt, boxes: hit.boxesAt,
                                              strikerID: hit.event.strikerID) {
                metres = Tactics.bisectorOffset(opponent: opp.court, apex: apex,
                                                bisector: cone.bisector).metres
            }
        }
        liveHits.append((hit.event.frame, metres))
    }
}
print("CAUSAL contacts: \(liveHits.count)")
for (f, m) in liveHits {
    print(String(format: "  frame %d  opponent %.1fm off%@", f, m,
                 m > outOfPositionM ? "  OUT OF POSITION" : ""))
}
