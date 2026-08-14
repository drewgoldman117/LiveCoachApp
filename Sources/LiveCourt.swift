// LiveCourt.swift
//
// Port of live.py's LiveCourt: acquires the court map while the session runs,
// and keeps it current.
//
// Calibrating once at startup is enough for a recorded file and not enough for
// a real camera. Two failures show up immediately in the field, both observed
// in the Python prototype rather than imagined:
//
//   1. The court may not be usable at t=0 - the camera can open on a close-up,
//      on someone crossing frame, or on its own auto-exposure settling. A
//      one-shot attempt then leaves the WHOLE session with no court map, no
//      overlay, no contacts, no alerts. Measured on the prototype's clips, 2 of
//      8 failed the startup attempt and were rescued by background retry (they
//      acquired at 18s and 30s).
//   2. A phone zip-tied to a fence gets nudged. A fit made twenty minutes ago
//      is then silently wrong - exactly the failure a hand calibration can
//      never notice, and one of the reasons this app auto-calibrates at all.
//
// So detection keeps running: retry until acquired, then re-check periodically
// and re-detect ONLY when the current fit has stopped matching the paint. That
// last condition is deliberate - a fit still sitting on the lines is left alone
// rather than swapped for a fresh one of similar quality.
//
// Detection costs seconds, so it runs on a background queue and the capture
// callback only ever does a cheap `offer` (a downscaled grayscale copy).

import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate

final class LiveCourt: ObservableObject {

    enum State: Equatable {
        case searching          // no court map yet
        case ready(support: Double)
    }

    /// The current court map, or nil while searching. Published so the live
    /// view can show progress; the pipeline gets it through `onUpdate`.
    @Published private(set) var calibration: Calibration?
    @Published private(set) var state: State = .searching

    /// Called on the MAIN thread whenever a new court map is adopted, so the
    /// detector and the contact detector can be re-pointed at it.
    var onUpdate: ((Calibration) -> Void)?
    /// Called on the MAIN thread when the camera starts or stops moving.
    var onMovingChanged: ((Bool) -> Void)?

    // Tuning, matching live.py.
    /// Samples are spaced by TIME, not frame count. Counting frames ties the
    /// spacing to however fast the device happens to be running - at ~10fps a
    /// stride of 10 meant one sample per second and an eight-second wait before
    /// the first attempt. What the spacing actually has to guarantee is that the
    /// PLAYERS MOVE between samples, so the median erases them; that is a
    /// property of wall-clock time, not of frames.
    private let sampleInterval: TimeInterval = 0.4
    private let bufferCount = 8           // ~3s of span at 0.4s spacing
    private let minSamples = 6            // enough to median; first try at ~2.4s
    private let retrySeconds: TimeInterval = 15      // while there is NO map
    private let revalidateSeconds: TimeInterval = 120 // with a map, drift check
    private let driftSupport = 0.70       // below this, something moved
    /// Mean per-pixel difference between consecutive samples above which the
    /// camera is judged to be MOVING, so the buffer is thrown away and
    /// detection waits for it to be still. Deliberately high: a player running
    /// across a static frame changes a small fraction of pixels, a camera being
    /// carried changes nearly all of them.
    private static let movementMeanDiff = 12.0
    /// Below this, nothing in the scene is moving - an empty court. Sensor
    /// noise and a breeze in the trees put consecutive samples around 1-2, so
    /// 3.0 clears that while a single walking player sits well above it.
    private static let staticMeanDiff = 3.0
    private let minSupport = 0.80         // adopt only a confident fit (LOW_SUPPORT)

    /// Detection runs at this width; frames are downscaled to it. 1280 keeps a
    /// court line a couple of pixels wide (what lineMask needs) while keeping
    /// the ~200k-hypothesis search affordable on a phone.
    private let detectWidth = 1280

    /// All mutable state below is touched only on `lock`; `offer` is called
    /// from the capture queue and the detection runs on `queue`.
    private let lock = NSLock()
    private var ring: [[UInt8]] = []
    private var ringW = 0, ringH = 0
    private var lastSample = Date.distantPast
    private var busy = false
    /// `.distantPast`, not `Date()`: the retry gap exists to space out repeated
    /// attempts, and applying it before the FIRST one made the app sit doing
    /// nothing for 15s after the buffer was already full. Now the first attempt
    /// runs as soon as there are enough still frames to median (~8s), and only
    /// subsequent tries wait.
    private var lastAttempt = Date.distantPast
    private var current: Calibration?
    /// True while the camera is being moved - published so the UI can say so
    /// rather than showing a stalled "finding court".
    @Published private(set) var isMoving = false
    private let queue = DispatchQueue(label: "court.detect", qos: .utility)

    /// Throw away the current map and start hunting again immediately.
    ///
    /// The escape hatch for a fit that is confidently WRONG. Drift re-detection
    /// cannot catch that case by design - it fires when the fit stops matching
    /// the paint, and a wrong-but-plausible court matches paint perfectly well.
    /// Without this, such a fit is saved, seeds every later session, and there
    /// is no way to say "no, that isn't the court".
    func reset() {
        lock.lock()
        current = nil
        ring.removeAll()
        lastAttempt = .distantPast          // eligible to retry on the next frame
        lock.unlock()
        Calibration.reset()                 // and don't let it come back on relaunch
        DispatchQueue.main.async {
            self.calibration = nil
            self.state = .searching
        }
    }

    /// Seed with a saved map (may be nil). Seeding does NOT stop detection: a
    /// saved fit is a starting point to be re-checked, not a promise.
    func adopt(_ cal: Calibration?) {
        lock.lock(); current = cal; lock.unlock()
        if let cal {
            DispatchQueue.main.async {
                self.calibration = cal
                self.state = .ready(support: 1.0)
            }
        }
    }

    /// Offer the current camera frame.
    ///
    /// The stride check comes FIRST, before the conversion. Converting and then
    /// discarding 9 frames in 10 meant a full-frame color conversion 60 times a
    /// second on the capture thread for work that was thrown away - the capture
    /// thread is also where the two Core ML models run, so that is stolen
    /// directly from the frame rate.
    func offer(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let now = Date()
        let take = now.timeIntervalSince(lastSample) >= sampleInterval
        if take { lastSample = now }
        lock.unlock()
        guard take else { return }

        // The NATIVE buffer size, which is not the size detection runs at - see
        // `finish`. Everything downstream (Vision boxes, the overlay's
        // AspectFit) works in these coordinates.
        let nativeW = CVPixelBufferGetWidth(pixelBuffer)

        guard let (gray, w, h) = LiveCourt.grayscale(pixelBuffer, targetWidth: detectWidth) else { return }

        lock.lock()
        if ringW != w || ringH != h { ring.removeAll(); ringW = w; ringH = h }

        // Self-heal a map stored against a different pixel grid: one saved by a
        // build that published detection-space coordinates, or one from a
        // session whose capture format differed. Without this such a map is
        // silently reused at the wrong scale, which is the failure this whole
        // change exists to fix.
        if let c = current, c.frameWidth != nativeW {
            current = c.scaled(toFrameWidth: nativeW)
        }

        // THROW THE BUFFER AWAY IF THE CAMERA IS MOVING. The median only
        // removes players because everything else holds still; sample it while
        // the phone is being carried and aimed and it blends several viewpoints
        // into smear. Pulled from a real device, the frame the detector was
        // handed was exactly that: chain-link fence at four angles and a blur
        // where a hand passed the lens, with no court in it at all - so
        // detection "failed" on an input no algorithm could have used.
        // Starting the buffer over on movement means the first STILL stretch
        // after mounting is what gets used, instead of a mixture of the two.
        if let last = ring.last, Self.differs(last, gray) {
            ring.removeAll()
            lock.unlock()
            DispatchQueue.main.async { if !self.isMoving { self.isMoving = true; self.onMovingChanged?(true) } }
            return
        }
        DispatchQueue.main.async { if self.isMoving { self.isMoving = false; self.onMovingChanged?(false) } }
        ring.append(gray)
        if ring.count > bufferCount { ring.removeFirst() }

        // AN EMPTY COURT NEEDS NO MEDIAN. The median exists solely to erase
        // players; with nobody on court there is nothing to erase, and waiting
        // 2.4s to average six identical frames is a tax paid for a problem that
        // isn't there. If consecutive samples are near-identical the scene is
        // static, so one frame is as good as six and setup becomes immediate.
        //
        // The threshold sits far below `movementMeanDiff`, which asks a
        // different question: that one separates a camera being carried from
        // players running, this one asks whether ANYTHING is moving at all.
        let sceneStatic = ring.count >= 2
            && Self.meanDiff(ring[ring.count - 2], ring[ring.count - 1]) < Self.staticMeanDiff
        let needed = sceneStatic ? 2 : minSamples

        let gap = (current == nil) ? retrySeconds : revalidateSeconds
        guard !busy, ring.count >= needed,
              Date().timeIntervalSince(lastAttempt) >= gap else { lock.unlock(); return }
        lastAttempt = Date()
        busy = true
        let frames = ring, existing = current
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let det = LiveCourt.work(frames: frames, width: w, height: h,
                                     existing: existing?.scaled(toFrameWidth: w),
                                     driftSupport: self.driftSupport,
                                     minSupport: self.minSupport)
            self.finish(det, width: w, height: h, nativeWidth: nativeW)
        }
    }

    /// PUBLISH IN NATIVE BUFFER COORDINATES, NOT DETECTION COORDINATES.
    ///
    /// Detection runs on a `detectWidth`-wide downscale, so the homography it
    /// returns maps 1280x960 pixels to meters. Everything that consumes a
    /// Calibration works in the FULL buffer's pixels: Vision reports boxes
    /// against `CVPixelBufferGetWidth`, and every overlay is drawn through
    /// `AspectFit(videoSize: camera.videoSize)`, which is also the native size.
    /// Handing those consumers a detection-space homography scales the entire
    /// court by nativeWidth/detectWidth.
    ///
    /// Measured on a real device at 1920x1440 native: exactly 1.5x. The court
    /// was drawn with its near baseline at screen row 430 where the fit put it
    /// at 828 - "the right shape, too small, in the wrong place" - while the
    /// player boxes, already in native coordinates, landed correctly. The same
    /// factor silently corrupted every player position the alert depends on,
    /// which is the part that does not show up as a drawing glitch.
    private func finish(_ det: CourtDetection?, width: Int, height: Int, nativeWidth: Int) {
        lock.lock()
        busy = false
        guard let det else { lock.unlock(); return }
        let k = Double(nativeWidth) / Double(width)
        let cal = Calibration(frameWidth: width, frameHeight: height,
                              imagePoints: det.imagePoints.map { [Double($0.x), Double($0.y)] },
                              homography: det.homography.m,
                              homographyInv: det.homographyInv.m).scaled(by: k)
        current = cal
        lock.unlock()

        try? cal.save()          // survives relaunch; next session starts with a map
        DispatchQueue.main.async {
            self.calibration = cal
            self.state = .ready(support: det.support)
            self.onUpdate?(cal)
        }
    }

    /// The background job. Returns a NEW detection only when one should be
    /// adopted; nil means "keep what we have".
    private static func work(frames: [[UInt8]], width w: Int, height h: Int,
                             existing: Calibration?, driftSupport: Double,
                             minSupport: Double) -> CourtDetection? {
        let median = medianFrame(frames, count: w * h)

        if let existing {
            // Cheap first: does the fit we already have still sit on the paint?
            // If so there is nothing to do, and re-detecting would risk trading
            // a good fit for a marginal one.
            let mask = CourtDetect.lineMask(median, width: w, height: h,
                                            lineWidth: max(2, Int((Double(w) / 380).rounded())))
            let support = CourtDetect.dilate(mask, width: w, height: h,
                                             radius: CourtDetect.supportRadiusPx)
            let scored = CourtDetect.scoreHomography(existing.Hinv, support: support,
                                                     width: w, height: h).support
            if scored >= driftSupport { return nil }
        }

        // Dump the input BEFORE detecting, not only after. Writing it only on
        // completion means a detection that is slow, wedged, or cut short by
        // the user leaving the screen produces NO evidence at all - which is
        // exactly what happened on the first field attempt: no dump existed,
        // so there was no way to tell a detector failure from an attempt that
        // never ran.
        dumpDebug(median, width: w, height: h, det: nil, note: "attempting…")
        let started = Date()
        let det = CourtDetect.detect(gray: median, width: w, height: h)
        dumpDebug(median, width: w, height: h, det: det,
                  note: String(format: "took %.1fs", Date().timeIntervalSince(started)))
        guard let det, det.support >= minSupport else { return nil }
        return det
    }

    /// Write the median frame + verdict to Documents (pull with
    /// `xcrun devicectl device copy from --domain-type appDataContainer`).
    private static func dumpDebug(_ gray: [UInt8], width w: Int, height h: Int,
                                  det: CourtDetection?, note: String = "") {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var pixels = gray
        let verdict: String
        if let det {
            verdict = "support \(det.support)\ncompleteness \(det.completeness)\n"
                + "linesMatched \(det.linesMatched) (one-to-one)\n"
                + "surfaceUniformity \(CourtDetect.surfaceUniformity(det.homographyInv, gray: gray, width: w, height: h))\n"
                + "adopted \(det.support >= 0.80)\n"
                + "H \(det.homography.m)\n"
        } else {
            verdict = "no court in this attempt\n"
        }
        try? (verdict + "note \(note)\nsize \(w)x\(h)\nat \(Date())\n")
            .write(to: dir.appendingPathComponent("court_debug.txt"),
                   atomically: true, encoding: .utf8)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let cg = ctx.makeImage() else { return }
            let dest = dir.appendingPathComponent("court_debug.png")
            guard let d = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString,
                                                          1, nil) else { return }
            CGImageDestinationAddImage(d, cg, nil)
            CGImageDestinationFinalize(d)
        }
    }

    /// Is the scene meaningfully different between two samples - i.e. did the
    /// camera move?
    ///
    /// Sampled coarsely (every 16th pixel) because this runs on the capture
    /// thread and only needs to distinguish "someone is carrying the phone"
    /// from "a player ran across the court". Players moving inside a static
    /// frame change a small fraction of pixels; a camera that has moved changes
    /// nearly all of them, so the threshold is deliberately high.
    private static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        meanDiff(a, b) > movementMeanDiff
    }

    /// Mean absolute per-pixel difference, sampled every 16th pixel because
    /// this runs on the capture thread. `.infinity` for mismatched buffers, so
    /// every caller treats them as "changed" rather than "identical".
    static func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, a.count > 0 else { return .infinity }
        var sum = 0, n = 0
        var i = 0
        while i < a.count {
            sum += abs(Int(a[i]) - Int(b[i]))
            n += 1
            i += 16
        }
        return n > 0 ? Double(sum) / Double(n) : .infinity
    }

    /// Per-pixel median - players and the ball vanish, the court stays. The
    /// SAMPLING STRIDE is what makes this work: consecutive frames have the
    /// players in the same place, so they would survive the median.
    private static func medianFrame(_ frames: [[UInt8]], count: Int) -> [UInt8] {
        guard let first = frames.first else { return [] }
        if frames.count == 1 { return first }
        var out = [UInt8](repeating: 0, count: count)
        var scratch = [UInt8](repeating: 0, count: frames.count)
        let mid = frames.count / 2
        for i in 0..<count {
            for (k, f) in frames.enumerated() { scratch[k] = f[i] }
            scratch.sort()
            out[i] = scratch[mid]
        }
        return out
    }

    // MARK: - Pixel buffer -> downscaled grayscale

    /// Luma plane of a 420f/420v buffer (or BGRA converted), downscaled to
    /// `targetWidth`. Grayscale is all CourtDetect needs, and the luma plane is
    /// already exactly that - no color conversion required for the common case.
    static func grayscale(_ pb: CVPixelBuffer, targetWidth: Int) -> ([UInt8], Int, Int)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let srcW = CVPixelBufferGetWidth(pb), srcH = CVPixelBufferGetHeight(pb)
        var srcGray = [UInt8](repeating: 0, count: srcW * srcH)

        if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<srcH {
                memcpy(&srcGray[y * srcW], p + y * stride, srcW)
            }
        } else if fmt == kCVPixelFormatType_32BGRA {
            // This is the format CameraManager actually requests, so it is the
            // hot path - vImage, not a scalar per-pixel loop (which was ~2M
            // iterations per frame at 1080p).
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            var src = vImage_Buffer(data: base, height: vImagePixelCount(srcH),
                                    width: vImagePixelCount(srcW),
                                    rowBytes: CVPixelBufferGetBytesPerRow(pb))
            let ok: vImage_Error = srcGray.withUnsafeMutableBufferPointer { buf -> vImage_Error in
                var dst = vImage_Buffer(data: buf.baseAddress, height: vImagePixelCount(srcH),
                                        width: vImagePixelCount(srcW), rowBytes: srcW)
                // Luma weights scaled by 256, in MEMORY order for BGRA:
                // 0.114*B + 0.587*G + 0.299*R + 0*A.
                let coeffs: [Int16] = [29, 150, 77, 0]
                return coeffs.withUnsafeBufferPointer { m in
                    vImageMatrixMultiply_ARGB8888ToPlanar8(&src, &dst, m.baseAddress!, 256,
                                                           nil, 0, vImage_Flags(kvImageNoFlags))
                }
            }
            guard ok == kvImageNoError else { return nil }
        } else {
            return nil
        }

        if srcW <= targetWidth { return (srcGray, srcW, srcH) }
        let dstW = targetWidth
        let dstH = max(1, Int((Double(srcH) * Double(dstW) / Double(srcW)).rounded()))
        var dst = [UInt8](repeating: 0, count: dstW * dstH)
        var srcBuf = vImage_Buffer(data: &srcGray, height: vImagePixelCount(srcH),
                                   width: vImagePixelCount(srcW), rowBytes: srcW)
        var dstBuf = vImage_Buffer(data: &dst, height: vImagePixelCount(dstH),
                                   width: vImagePixelCount(dstW), rowBytes: dstW)
        guard vImageScale_Planar8(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
                == kvImageNoError else { return (srcGray, srcW, srcH) }
        return (dst, dstW, dstH)
    }
}
