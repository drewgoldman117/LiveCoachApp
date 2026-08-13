// CameraManager.swift
//
// AVCaptureSession configured for a fixed fence-mounted phone: landscape,
// 60fps (contact-latency and ball tracking both want 60 -- see CLAUDE.md).
// Delivers CVPixelBuffers to a frame handler for on-device detection, and
// vends the session so a preview layer can show the live camera image.
//
// 60fps matters twice over: the fine-tuned ball model needs the temporal
// density, and the (later) causal contact detector's lag scales with frame
// rate (~0.18s @ 60 vs ~0.37s @ 30). Don't let the phone silently drop to 30.

import AVFoundation
import CoreVideo

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    /// Called on `videoQueue` for every captured frame. The buffer is already
    /// oriented to landscape, so detection pixel coords line up with what the
    /// preview layer displays (.resizeAspect).
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Oriented frame dimensions (width, height) in pixels -- needed to map
    /// detection coordinates into the aspect-fit preview rect.
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var actualFPS: Double = 0
    @Published private(set) var isAuthorized = false

    /// Rotation applied to BOTH the capture output and the preview.
    ///
    /// 0 degrees is the camera's native landscape - the image running across the
    /// long edge of the phone, which is how it's mounted. Confirmed correct on
    /// device. This was never the wrong VALUE: the old code only assigned it
    /// `if isVideoRotationAngleSupported(0)` and skipped it in silence when that
    /// returned false, leaving the connection at its 90-degree portrait default.
    static let landscapeAngle: CGFloat = 0

    private let videoQueue = DispatchQueue(label: "camera.video.queue")
    private let output = AVCaptureVideoDataOutput()
    /// Guards against republishing the same size 60 times a second.
    private var lastReportedSize: CGSize = .zero

    func start() {
        requestAccess { [weak self] granted in
            guard let self, granted else { return }
            self.videoQueue.async {
                self.configure()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        videoQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    // MARK: - Setup

    private func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.isAuthorized = true }
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.isAuthorized = granted }
                completion(granted)
            }
        default:
            DispatchQueue.main.async { self.isAuthorized = false }
            completion(false)
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority   // let the chosen format drive resolution

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        selectBest60fpsFormat(for: device)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        for conn in output.connections { CameraManager.apply(Self.landscapeAngle, to: conn) }
        session.commitConfiguration()
        // videoSize is NOT set from the format here: see captureOutput. The
        // format reports the SENSOR's dimensions, which are not the delivered
        // buffer's if the connection is rotating.
    }

    /// Apply a rotation to a connection, falling back to the nearest supported
    /// quarter turn.
    ///
    /// The fallback exists because the original was
    /// `if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }`
    /// - when that check returned false the assignment was skipped in SILENCE
    /// and the connection kept its 90-degree default, i.e. portrait. Worse than
    /// cosmetic: the same rotated buffer feeds court detection, where a sideways
    /// court fails `plausiblePose` (far edge must sit above the near edge) and
    /// can never be found.
    static func apply(_ angle: CGFloat, to conn: AVCaptureConnection) {
        if conn.isVideoRotationAngleSupported(angle) {
            conn.videoRotationAngle = angle
            return
        }
        for fallback in [CGFloat(0), 90, 180, 270] where conn.isVideoRotationAngleSupported(fallback) {
            print("Camera: \(angle)° unsupported, using \(fallback)°")
            conn.videoRotationAngle = fallback
            return
        }
        print("Camera: no rotation angle supported; left at \(conn.videoRotationAngle)°")
    }

    /// Pick the highest-resolution format (capped ~1080p for speed) that runs
    /// at >= 60fps, then pin the frame duration to 60.
    private func selectBest60fpsFormat(for device: AVCaptureDevice) {
        var best: AVCaptureDevice.Format?
        var bestKey = (-1, -1)
        let maxWidth = 1920   // 1080p is a good speed/quality start; raise later

        var considered: [String] = []
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width <= maxWidth else { continue }
            let supports60 = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
            guard supports60 else { continue }
            considered.append("\(dims.width)x\(dims.height)")
            // Rank by WIDTH first, pixels second. Ranking by pixel count alone
            // picked a 4:3 format (1440x1080 = 1.55MP beats 16:9 1280x720 =
            // 0.92MP) - which is the wrong trade here: the wasted dimension is
            // HORIZONTAL field of view, and the court's width is what has to fit
            // in frame. A 4:3 capture also has to be cropped hard to fill a
            // 19.5:9 screen, throwing away more of it.
            let key = (Int(dims.width), Int(dims.width) * Int(dims.height))
            if key > bestKey { bestKey = key; best = format }
        }
        print("Camera: 60fps formats available: \(considered.joined(separator: ", "))")

        guard let chosen = best else {
            print("Camera: NO 60fps format found; leaving the default")
            return
        }
        let d = CMVideoFormatDescriptionGetDimensions(chosen.formatDescription)
        print("Camera: selected \(d.width)x\(d.height) @60fps")
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            let sixty = CMTime(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = sixty
            device.activeVideoMaxFrameDuration = sixty
            device.unlockForConfiguration()
        } catch {
            // Non-fatal: fall back to the default active format / frame rate.
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Publish the size of the buffer we ACTUALLY received, not the sensor
        // format's. A rotating connection delivers the transposed size, and
        // videoSize drives the aspect-fit mapping every overlay is drawn
        // through - so taking it from the format put boxes, foot dots and court
        // lines in the wrong places whenever the two disagreed.
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        if size != lastReportedSize {
            lastReportedSize = size
            DispatchQueue.main.async { self.videoSize = size }
        }

        onFrame?(pixelBuffer)
    }
}
