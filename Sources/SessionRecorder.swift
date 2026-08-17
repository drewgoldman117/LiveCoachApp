// SessionRecorder.swift
//
// Records the session as the user SEES it - ReplayKit captures the actual
// screen, so the file contains everything the app drew: camera image, court
// lines, boxes, ball, HUD, minimap, contact flashes, status pills. Watching
// it back answers the only question a field test asks: did it work?
//
// ReplayKit over hand-burning the overlay into camera frames, deliberately:
// a hand-drawn copy of the UI has to be maintained forever (every new HUD
// element silently missing from recordings until someone notices), while the
// screen IS the UI by definition. It also runs in the system's capture
// pipeline, off this app's frame budget - which two ML models at 60fps have
// no room to share. The trade: the file is screen-resolution with the UI
// chrome visible, i.e. a review artifact, not re-runnable clean footage.

import ReplayKit
import Photos

final class SessionRecorder {
    private let screen = RPScreenRecorder.shared()
    private var running = false

    /// Start capturing. iOS shows a system consent alert the first time per
    /// app launch; recording begins when the user allows it.
    func start() {
        guard screen.isAvailable, !running else { return }
        screen.isMicrophoneEnabled = false
        screen.startRecording { [weak self] error in
            if error == nil { self?.running = true }
        }
    }

    /// Stop and write the movie. Calls back on the main thread with the file
    /// URL, or nil if nothing was recorded (declined consent, never started).
    func finish(_ completion: @escaping (URL?) -> Void) {
        guard running else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        running = false
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: out)
        screen.stopRecording(withOutput: out) { error in
            DispatchQueue.main.async { completion(error == nil ? out : nil) }
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
