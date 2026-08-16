// SessionRecorder.swift
//
// Records the raw camera frames of a live session to a temp file, so the user
// can decide AT THE END whether it was worth keeping. The recording is the raw
// camera image, not the overlay - raw footage can be re-run through detection
// later (it is exactly the input the Python prototype consumes), while
// overlay-burned video can't be.
//
// Writing happens on the capture callback with a hardware encoder and
// expectsMediaDataInRealTime, so the cost per frame is a submit, not an
// encode - it does not compete with the models for the frame budget.

import AVFoundation
import Photos

final class SessionRecorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private(set) var url: URL?

    /// Frames arrive here on the capture queue. The writer is created lazily
    /// from the FIRST sample buffer, because that is when the true delivered
    /// dimensions (post-rotation) are known.
    func append(_ sampleBuffer: CMSampleBuffer) {
        if writer == nil { start(with: sampleBuffer) }
        guard let writer, let input, writer.status == .writing else { return }
        if !started {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
        // Not ready -> drop the frame. Blocking here would block the capture
        // queue, which also feeds both detection models.
    }

    private func start(with sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: out)
        guard let w = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        guard w.canAdd(inp) else { return }
        w.add(inp)
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
