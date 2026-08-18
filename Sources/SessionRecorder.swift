// SessionRecorder.swift
//
// Records the session as the user SEES it - the actual screen, so the file
// contains everything the app drew - plus the microphone, so the sound of a
// strike lines up against the video on review.
//
// STREAMING, not buffered, and that is the load-bearing choice. The first
// version used RPScreenRecorder.startRecording + stopRecording(withOutput:),
// which holds the WHOLE recording in the system service and exports it once
// at the end - and long sessions are exactly where that export fails, with
// the failure surfacing as "no save dialog appeared", i.e. it looks like the
// app never recorded at all. startCapture hands over sample buffers as they
// happen and AVAssetWriter appends them straight to disk, so session length
// stops being a variable and a recording that dies is visible (isRecording)
// instead of silent.

import ReplayKit
import AVFoundation
import Photos

final class SessionRecorder: NSObject, ObservableObject {
    /// Live capture state, so the UI can show a REC dot - a recording that
    /// quietly died mid-session must not look identical to one that ran.
    @Published private(set) var isRecording = false

    private let screen = RPScreenRecorder.shared()
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var started = false
    private var finishing = false
    private(set) var url: URL?
    private let lock = NSLock()

    func start() {
        guard screen.isAvailable, !isRecording else { return }
        screen.isMicrophoneEnabled = true
        screen.startCapture(handler: { [weak self] sb, type, error in
            guard error == nil else { return }
            self?.append(sb, type)
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async { self?.isRecording = (error == nil) }
        })
    }

    /// Buffers arrive on ReplayKit's own queues (video and audio separately).
    private func append(_ sb: CMSampleBuffer, _ type: RPSampleBufferType) {
        guard CMSampleBufferDataIsReady(sb) else { return }
        lock.lock()
        defer { lock.unlock() }
        if finishing { return }
        if writer == nil, type == .video { setup(from: sb) }
        guard let writer, writer.status == .writing else { return }

        switch type {
        case .video:
            if !started {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
                started = true
            }
            if let video, video.isReadyForMoreMediaData { video.append(sb) }
        case .audioMic:
            // Video first: audio appended before startSession is an error.
            guard started else { return }
            if let audio, audio.isReadyForMoreMediaData { audio.append(sb) }
        default:
            break   // .audioApp: the app plays no sound worth keeping
        }
    }

    private func setup(from sb: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: out)
        guard let w = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return }

        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
        ])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(v), w.canAdd(a) else { return }
        w.add(v)
        w.add(a)
        guard w.startWriting() else { return }
        writer = w
        video = v
        audio = a
        url = out
    }

    /// Stop capturing and close the file. Calls back on the main thread with
    /// the URL, or nil if nothing usable was recorded.
    func finish(_ completion: @escaping (URL?) -> Void) {
        screen.stopCapture { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.finishing = true
            let writer = self.writer
            let started = self.started
            let url = self.url
            self.lock.unlock()
            DispatchQueue.main.async { self.isRecording = false }

            guard let writer, started, writer.status == .writing else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.video?.markAsFinished()
            self.audio?.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async { completion(url) }
            }
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
