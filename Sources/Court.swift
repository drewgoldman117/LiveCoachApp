// Court.swift
//
// Direct port of the Python prototype's src/court.py. Singles-court geometry
// and the coordinate convention that cuts across the whole app.
//
// Coordinate convention (must match the Python repo exactly):
//   Origin = center of MY baseline (the camera's own baseline).
//   +Y points AWAY from the camera, toward the opponent's far baseline.
//   +X is lateral (to the right). Units are METERS everywhere except raw
//   pixel coordinates, which only exist between a detection box and the
//   homography call.
//
// The tactical goal only ever needs accuracy in the FAR half (Y > NET_Y_M).

import Foundation
import CoreGraphics

enum Court {
    static let lengthM: Double = 23.77          // baseline to baseline
    static let widthM: Double = 8.23            // singles sideline to sideline
    static let halfWidthM: Double = widthM / 2  // 4.115

    static let netY: Double = lengthM / 2                       // 11.885
    static let serviceLineDistFromNet: Double = 6.40
    static let farServiceLineY: Double = netY + serviceLineDistFromNet   // 18.285
    static let nearServiceLineY: Double = netY - serviceLineDistFromNet  // 5.485

    // Click order during calibration: far baseline, far service line, net,
    // near baseline -- each a left/right pair -> 8 landmark points.
    // If the camera can't see its own baseline, drop the last pair and
    // calibrate on the first 6 (see court.py notes).
    static let cornerLabels: [String] = [
        "far baseline, LEFT",
        "far baseline, RIGHT",
        "far service line, LEFT",
        "far service line, RIGHT",
        "net, LEFT",
        "net, RIGHT",
        "near baseline, LEFT",
        "near baseline, RIGHT",
    ]

    // Real-world court coordinates (meters) for each landmark, in click order.
    static let corners: [CGPoint] = [
        CGPoint(x: -halfWidthM, y: lengthM),          // far baseline, left
        CGPoint(x:  halfWidthM, y: lengthM),          // far baseline, right
        CGPoint(x: -halfWidthM, y: farServiceLineY),  // far service line, left
        CGPoint(x:  halfWidthM, y: farServiceLineY),  // far service line, right
        CGPoint(x: -halfWidthM, y: netY),             // net, left
        CGPoint(x:  halfWidthM, y: netY),             // net, right
        CGPoint(x: -halfWidthM, y: 0.0),              // near baseline, left
        CGPoint(x:  halfWidthM, y: 0.0),              // near baseline, right
    ]

    // Horizontal line pairs (left,right index) and the two sideline chains,
    // derived from `corners` length so they adapt if points are added/removed
    // -- mirrors calibrate.py's _LINE_PAIRS / _SIDELINE_CHAINS.
    static var linePairs: [(Int, Int)] {
        stride(from: 0, to: corners.count, by: 2).map { ($0, $0 + 1) }
    }
    static var sidelineChains: [[Int]] {
        [Array(stride(from: 0, to: corners.count, by: 2)),
         Array(stride(from: 1, to: corners.count, by: 2))]
    }

    // Court segments to draw (pairs of court-meter points), for reprojecting
    // the court outline onto the camera image.
    static var courtSegments: [(CGPoint, CGPoint)] {
        var segs: [(CGPoint, CGPoint)] = []
        for (a, b) in linePairs { segs.append((corners[a], corners[b])) }
        for chain in sidelineChains {
            for i in 1..<chain.count { segs.append((corners[chain[i - 1]], corners[chain[i]])) }
        }
        return segs
    }
}
