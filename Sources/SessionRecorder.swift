// SessionRecorder.swift
//
// Records the live session WITH its overlay burned in - court lines, player
// boxes, foot dots, the ball - so watching the file back answers the only
// question a field test asks: did detection work?
//
// The frames come from the PIPELINE after detection has consumed them, not
// from the capture callback. That ordering is the point, and it is this
// project's oldest bug class (draw-before-detect): painting boxes onto a
// buffer the detector has not read yet feeds it painted pixels. Here the
// pipeline appends only after both models have run, so the recorder can draw
// directly into the capture buffer without corrupting anything downstream.
//
// The recording therefore contains exactly the frames the app PROCESSED, at
// the rate it processed them (real timestamps, so playback speed is correct).
// That is the honest record of a session - dropped frames are dropped in the
// file too, the same way the app experienced them.

import AVFoundation
import CoreGraphics
import Photos

final class SessionRecorder {

    /// What to draw on one frame, in buffer pixel coordinates.
    struct Overlay {
        var courtSegments: [(CGPoint, CGPoint)] = []
        var boxes: [CGRect] = []
        var feet: [CGPoint] = []
        var ball: CGPoint?
    }

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false
    private(set) var url: URL?

    /// Called on the capture queue, AFTER detection has read the buffer.
    func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime, overlay: Overlay) {
        if writer == nil { start(with: pixelBuffer) }
        guard let writer, let input, let adaptor, writer.status == .writing else { return }
        if !started {
            writer.startSession(atSourceTime: time)
            started = true
        }
        guard input.isReadyForMoreMediaData else { return }   // drop, never block
        draw(overlay, into: pixelBuffer)
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    /// Burn the overlay into the BGRA capture buffer with CoreGraphics.
    private func draw(_ overlay: Overlay, into pb: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base,
                                  width: CVPixelBufferGetWidth(pb),
                                  height: CVPixelBufferGetHeight(pb),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        // Buffer row 0 is the image top; CG's origin is bottom-left. Flip once
        // so everything below works in the same top-left pixel coords as
        // detection.
        let h = CGFloat(CVPixelBufferGetHeight(pb))
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)

        if !overlay.courtSegments.isEmpty {
            ctx.setStrokeColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1)   // orange
            ctx.setLineWidth(5)
            for (a, b) in overlay.courtSegments {
                ctx.move(to: a)
                ctx.addLine(to: b)
            }
            ctx.strokePath()
        }
        if !overlay.boxes.isEmpty {
            ctx.setStrokeColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1)    // green
            ctx.setLineWidth(3)
            for box in overlay.boxes { ctx.stroke(box) }
            ctx.setFillColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1)    // red feet
            for f in overlay.feet {
                ctx.fillEllipse(in: CGRect(x: f.x - 7, y: f.y - 7, width: 14, height: 14))
            }
        }
        if let ball = overlay.ball {
            ctx.setFillColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 1)      // yellow
            ctx.fillEllipse(in: CGRect(x: ball.x - 9, y: ball.y - 9, width: 18, height: 18))
        }
    }

    private func start(with pb: CVPixelBuffer) {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: out)
        guard let w = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: CVPixelBufferGetWidth(pb),
            AVVideoHeightKey: CVPixelBufferGetHeight(pb),
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        guard w.canAdd(inp) else { return }
        w.add(inp)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp,
                                                       sourcePixelBufferAttributes: nil)
        guard w.startWriting() else { return }
        writer = w
        input = inp
        url = out
    }

    /// Close the file. Calls back on the main thread with the finished URL,
    /// or nil if nothing was recorded.
    func finish(_ completion: @escaping (URL?) -> Void) {
        guard let writer, started, writer.status == .writing else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        input?.markAsFinished()
        let url = self.url
        writer.finishWriting {
            DispatchQueue.main.async { completion(url) }
        }
    }

    /// Save a finished recording into the photo library, then delete the temp
    /// file either way - keeping it would silently fill the phone.
    static func saveToPhotos(_ url: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
