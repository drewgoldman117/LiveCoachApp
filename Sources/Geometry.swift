// Geometry.swift
//
// The single frame<->view coordinate transform every overlay goes through.
//
// Aspect-FILL, matching the preview layer's .resizeAspectFill: the camera image
// covers the whole screen and the overhang is cropped, rather than being
// letterboxed into black bars.
//
// The preview and this transform MUST agree. This is how a detection in buffer
// pixels becomes a box on screen, so if one fills while the other fits, every
// box, foot dot and court line is drawn at the wrong scale and offset. The only
// difference from the fit version is min -> max, which makes the offsets
// negative (the image starts off-screen) instead of positive.

import CoreGraphics

struct AspectFit {
    let scale: CGFloat
    let offset: CGPoint
    let displaySize: CGSize

    init(videoSize: CGSize, viewSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0 else {
            scale = 1; offset = .zero; displaySize = viewSize; return
        }
        let s = max(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        scale = s
        displaySize = CGSize(width: videoSize.width * s, height: videoSize.height * s)
        offset = CGPoint(x: (viewSize.width - displaySize.width) / 2,
                         y: (viewSize.height - displaySize.height) / 2)
    }

    /// Frame pixel coords -> view coords.
    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    /// View coords -> frame pixel coords (for recording taps during calibration).
    func toFrame(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }
}
