// LiveView.swift
//
// The live-detection milestone: camera image + player boxes/foot-dots, tracked
// ball, reprojected court lines, a top-down minimap, and an FPS/latency HUD.
// This is the on-device equivalent of `python src/live.py` with the detection +
// court-overlay layer (contacts / cones / alerts come in later milestones).

import SwiftUI
import CoreVideo
import CoreMedia

// MARK: - Pipeline (camera -> detector -> published result)

final class LivePipeline: ObservableObject {
    @Published var result = FrameResult()
    @Published var fps: Double = 0
    @Published var detectorReady = true

    /// Ball detection rate over the last 10s, and the session's BEST window.
    /// Ported from live.py's field-diagnostics HUD, and the two windows are
    /// the point: the rate is naturally ~0 between points, so the live number
    /// alone makes healthy tracking look broken after every rally - the best
    /// window is the verdict on whether the model can see the ball on this
    /// court at all. Healthy reference on footage known to work: 32-47%.
    @Published var ballRate: Double = 0
    @Published var ballRateBest: Double = 0
    /// (timestamp, ball seen) for the rolling window - capture queue only.
    private var ballWindow: [(t: CFTimeInterval, hit: Bool)] = []

    /// Accumulates this session so the home screen can report a real figure
    /// afterwards rather than a decorative one.
    let session = SessionTracker()

    /// The contact flash + shot cone + opponent connector currently on screen,
    /// and how many more frames it stays for.
    @Published var flash: ContactFlash?
    @Published var alerts = 0

    private let detector: Detector?
    /// The court map IN USE. Not a `let`: LiveCourt can find one mid-session
    /// (the camera may not have been showing a usable court at t=0) or replace
    /// one that drifted when the phone was knocked, and everything downstream
    /// has to follow.
    @Published private(set) var calibration: Calibration?
    /// Finds and maintains that court map in the background. This is why the
    /// app no longer requires tapping the 8 corners.
    let court: LiveCourt
    /// Mirrored from `court`, because SwiftUI does not observe a nested
    /// ObservableObject - reading court.isMoving directly would never redraw.
    @Published private(set) var cameraIsMoving = false
    private let buzzer: BuzzerLink?
    private var contacts: LiveContactDetector?
    /// A court map waiting to be applied on the capture queue (see `adopt`).
    private var pendingCalibration: Calibration?
    /// Set by `resetCourt` on the main thread, consumed on the capture queue.
    private var pendingReset = false
    private let pendingLock = NSLock()
    /// The map the capture queue is working in. Distinct from `calibration`,
    /// which exists for the UI and is only touched on the main thread.
    private var courtMapForFrame: Calibration?
    private var flashFramesLeft = 0
    private var lastFrameTime: CFTimeInterval = 0
    /// Frame rate as MEASURED on the processing queue - not the capture rate.
    /// Late frames are discarded upstream, so these differ whenever the models
    /// can't keep up, and the contact detector must use this one.
    private var processedFPS: Double = 0
    private var framesSeen = 0

    /// Processed frames a flash stays visible (~0.3s at 30fps).
    private let flashFrames = 10

    init(camera: CameraManager, calibration: Calibration?, buzzer: BuzzerLink?) {
        detector = Detector(calibration: calibration)
        detectorReady = (detector != nil)
        self.calibration = calibration
        self.courtMapForFrame = calibration
        self.buzzer = buzzer
        // A saved map (if any) seeds the detector, which then keeps checking it
        // rather than trusting it forever.
        court = LiveCourt()
        // Contacts need the ball AND a court map (the gates are in court meters).
        if let cal = calibration {
            // 60fps capture (see CameraManager): the lag is ~11 frames, so 0.18s.
            contacts = LiveContactDetector(fps: 60, homography: cal.H)
        }
        court.adopt(calibration)
        court.onUpdate = { [weak self] cal in self?.adopt(cal) }
        court.onMovingChanged = { [weak self] moving in self?.cameraIsMoving = moving }
        camera.onFrame = { [weak self] pixelBuffer, pts in
            self?.handle(pixelBuffer, at: pts)
        }
    }

    /// Queue a court map found (or re-found) mid-session.
    ///
    /// LiveCourt reports on the MAIN thread, but `detector` and `contacts` are
    /// read on the capture queue - assigning them here would be a data race on a
    /// struct-typed property, which tears or crashes rarely enough to look like
    /// a mystery in the field. So the new map is parked under a lock and applied
    /// at the top of `handle`, on the queue that consumes it.
    private func adopt(_ cal: Calibration) {
        calibration = cal                      // @Published, main thread: the UI
        pendingLock.lock()
        pendingCalibration = cal
        pendingLock.unlock()
    }

    /// Throw the current court map away and start detecting again.
    ///
    /// Everything downstream has to be cleared with it, not just the overlay:
    /// leaving the detector and contact detector pointed at the old homography
    /// would keep producing court positions and out-of-position meters in a
    /// court the user has just said is wrong.
    /// Called on the MAIN thread (a button). It may only touch main-thread
    /// state; `detector`, `contacts` and `courtMapForFrame` belong to the
    /// capture queue, so the clear is queued and applied there - the same rule
    /// as adopting a new map.
    func resetCourt() {
        court.reset()
        calibration = nil
        pendingLock.lock()
        pendingCalibration = nil
        pendingReset = true
        pendingLock.unlock()
    }

    /// Apply a queued court map. Called only from the capture queue.
    private func applyPendingCalibration() {
        pendingLock.lock()
        let pending = pendingCalibration
        let reset = pendingReset
        pendingCalibration = nil
        pendingReset = false
        pendingLock.unlock()

        if reset {
            // Clear everything holding the rejected homography, not just the
            // overlay: a stale detector would keep reporting court positions,
            // and a stale contact detector out-of-position meters, in a court
            // the user has just said is wrong.
            courtMapForFrame = nil
            detector?.calibration = nil
            contacts = nil
        }
        guard let cal = pending else { return }
        detector?.calibration = cal            // a `var`, so no model reload
        if let contacts {
            contacts.homography = cal.H
        } else {
            contacts = LiveContactDetector(fps: 60, homography: cal.H)
        }
        courtMapForFrame = cal
    }

    private func handle(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) {
        guard let detector else { return }
        applyPendingCalibration()
        // Court detection gets the frame too. It samples every 10th and does the
        // expensive work on its own queue, so this costs a downscale, not a fit.
        court.offer(pixelBuffer)
        let r = detector.process(pixelBuffer)

        let now = CACurrentMediaTime()
        let dt = now - lastFrameTime
        lastFrameTime = now
        let instantFPS = dt > 0 ? 1.0 / dt : 0

        // Track the delivered rate here on the video queue, and re-base the
        // contact detector on it once it has settled (a cold start's first
        // frames are not representative).
        framesSeen += 1
        processedFPS = processedFPS == 0 ? instantFPS : processedFPS * 0.9 + instantFPS * 0.1
        if framesSeen % 30 == 0, framesSeen >= 60 {
            contacts?.setFrameRate(processedFPS)
        }

        // --- contacts -> shot cone -> opponent offset -> buzz ---
        var newFlash: ContactFlash?
        // courtMapForFrame, not `calibration`: this runs on the capture queue.
        if let contacts, let cal = courtMapForFrame {
            let boxes = r.players.map { ContactBox(id: $0.id, rect: $0.boxPx) }
            let court = Dictionary(uniqueKeysWithValues: r.players.map { ($0.id, $0.courtPos) })
            for hit in contacts.update(ballPx: r.ballPx, boxes: boxes, court: court) {
                guard let apex = hit.apexCourt else { continue }
                let cone = Tactics.shotCone(apex: apex)

                var reco: ContactFlash.Recovery?
                // Measured at the CONTACT frame (courtAt/boxesAt), never at this
                // one - see LiveContactDetector.update.
                if let opp = Tactics.findOpponent(courtPositions: hit.courtAt,
                                                  boxes: hit.boxesAt,
                                                  strikerID: hit.event.strikerID) {
                    let off = Tactics.bisectorOffset(opponent: opp.court, apex: apex,
                                                     bisector: cone.bisector)
                    reco = ContactFlash.Recovery(opponentPx: opp.footPx,
                                                 idealCourt: off.foot,
                                                 meters: off.meters)
                    if off.meters > outOfPositionM {
                        buzzer?.buzz()
                        DispatchQueue.main.async { self.alerts += 1 }
                    }
                }
                newFlash = ContactFlash(strikerID: hit.event.strikerID,
                                        ballPx: hit.event.ballPx,
                                        apexCourt: apex,
                                        cone: cone,
                                        recovery: reco)
            }
            _ = cal
        }

        // Rolling 10s ball-detection rate (capture queue owns ballWindow).
        ballWindow.append((now, r.ballPx != nil))
        while let first = ballWindow.first, now - first.t > 10 { ballWindow.removeFirst() }
        let rate = Double(ballWindow.filter(\.hit).count) / Double(max(1, ballWindow.count))
        // Only a reasonably full window may set the session best - a 1-frame
        // window at session start would otherwise pin it to 0% or 100%.
        let windowFull = (now - (ballWindow.first?.t ?? now)) > 8

        DispatchQueue.main.async {
            self.result = r
            // Exponential moving average so the HUD number is readable.
            self.fps = self.fps == 0 ? instantFPS : self.fps * 0.9 + instantFPS * 0.1
            self.ballRate = rate
            if windowFull { self.ballRateBest = max(self.ballRateBest, rate) }
            self.session.tick(fps: instantFPS)
            if let newFlash {
                self.flash = newFlash
                self.flashFramesLeft = self.flashFrames
            } else if self.flashFramesLeft > 0 {
                self.flashFramesLeft -= 1
                if self.flashFramesLeft == 0 { self.flash = nil }
            }
        }
    }
}

/// What to draw for a contact: the strike itself, the shot cone, and how far
/// the opponent was off the bisector when it happened.
struct ContactFlash {
    struct Recovery {
        let opponentPx: CGPoint
        let idealCourt: CGPoint
        let meters: Double
    }
    let strikerID: Int?
    let ballPx: CGPoint
    let apexCourt: CGPoint
    let cone: (left: CGPoint, right: CGPoint, bisector: CGPoint)
    let recovery: Recovery?
}

// MARK: - Live view

struct LiveView: View {
    @ObservedObject var camera: CameraManager
    let calibration: Calibration?
    let onEnd: () -> Void
    @StateObject private var pipeline: LivePipeline
    /// The session recording, decided on at END: save to Photos or discard.
    @StateObject private var recorder = SessionRecorder()
    @State private var finishedRecording: URL?
    @State private var askAboutRecording = false
    /// Big green check flashed when the court map is (re)acquired - the one
    /// moment worth celebrating out loud, since everything else waits on it.
    @State private var showCourtFound = false
    /// "BEEP" banner while the buzzer fires, so the video shows WHEN the alert
    /// went out even though the sound comes from the wearer's buzzer.
    @State private var showBeep = false

    init(camera: CameraManager, calibration: Calibration?, buzzer: BuzzerLink? = nil,
         onEnd: @escaping () -> Void = {}) {
        self.camera = camera
        self.calibration = calibration
        self.onEnd = onEnd
        _pipeline = StateObject(wrappedValue: LivePipeline(camera: camera,
                                                          calibration: calibration,
                                                          buzzer: buzzer))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreview(session: camera.session, angle: camera.captureAngle)
                // pipeline.calibration, NOT the one passed in: the court map can
                // arrive (or be replaced) mid-session.
                OverlayView(result: pipeline.result,
                            calibration: pipeline.calibration,
                            ballRate: pipeline.ballRate,
                            ballRateBest: pipeline.ballRateBest,
                            videoSize: camera.videoSize,
                            viewSize: geo.size,
                            fps: pipeline.fps,
                            flash: pipeline.flash)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if !pipeline.detectorReady {
                    Text("MODELS NOT IN BUNDLE — ADD PlayerDetector & BallDetector .mlpackage")
                        .font(DS.Font.label)
                        .tracking(DS.Metric.labelTracking)
                        .padding(8)
                        .background(DS.Color.alert).foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                // Say plainly that the court is still being looked for. Without
                // this, a session with no map yet looks identical to a broken
                // one - the same reason live.py prints a COURT status.
                if pipeline.calibration == nil {
                    // Say which of the two states it is. "Finding court" while
                    // the phone is being carried looks identical to "finding
                    // court" while it is mounted and failing, and only one of
                    // those is the user's to fix.
                    Text(pipeline.cameraIsMoving ? "HOLD STILL — WAITING FOR THE CAMERA TO SETTLE"
                                                 : "FINDING COURT…")
                        .font(DS.Font.label)
                        .tracking(DS.Metric.labelTracking)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.55)).foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 8)
        }
        .overlay {
            if showCourtFound {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 110))
                    .foregroundStyle(.green)
                    .shadow(radius: 8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            // A recording that died must not look like one that ran.
            if recorder.isRecording {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("REC").font(.caption2.monospaced().bold()).foregroundStyle(.white)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.5)).clipShape(Capsule())
                .padding(.leading, 12).padding(.top, 44)
            }
        }
        .overlay(alignment: .top) {
            if showBeep {
                // Same scale as the rest of the top chrome - it announces,
                // it doesn't cover the court.
                Text("BEEP")
                    .font(DS.Font.label.bold())
                    .tracking(DS.Metric.labelTracking)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.yellow)
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: pipeline.alerts) { _, _ in
            withAnimation(.spring(duration: 0.25)) { showBeep = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) { showBeep = false }
            }
        }
        .onChange(of: pipeline.calibration != nil) { had, has in
            guard has, !had else { return }
            withAnimation(.spring(duration: 0.3)) { showCourtFound = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeOut(duration: 0.4)) { showCourtFound = false }
            }
        }
        // Session chrome, in the same visual language as the home screen. Placed
        // top-trailing so it stays clear of the HUD (top-left) and the minimap
        // (bottom-right) the overlay already draws.
        .overlay(alignment: .topTrailing) {
            // No "recalibrate" button: the court map maintains ITSELF now
            // (LiveCourt re-detects when the fit stops matching the paint), so
            // offering a manual re-do would be asking for work the app already
            // does, and doing it mid-session would only interrupt play.
            // No rotate control: 0 degrees is confirmed correct on device, so
            // the camera is simply pinned to it (CameraManager.landscapeAngle).
            HStack(spacing: 8) {
                // NOT the old "recalibrate" (which opened a tap screen). This
                // throws the court map away and makes detection start over. It
                // belongs in the session because that is where a wrong court is
                // visible, and automatic drift re-detection cannot rescue this
                // case by design: it fires when a fit stops matching the paint,
                // and a confidently-wrong court matches paint perfectly well.
                // Flip is ALWAYS available - unlike "reset court" it is most
                // needed before any court map exists, because flipping is how
                // the correct camera gets pointed at the court to begin with.
                ChromeButton(title: "flip cam", systemImage: "arrow.triangle.2.circlepath.camera") {
                    camera.flip()
                    // A different camera is a different framing AND different
                    // optics - the old homography describes neither. Throw it
                    // away and let detection start over on the new view.
                    pipeline.resetCourt()
                }
                if pipeline.calibration != nil {
                    ChromeButton(title: "reset court", systemImage: "arrow.counterclockwise") {
                        pipeline.resetCourt()
                    }
                }
                ChromeButton(title: "end", systemImage: "stop.fill",
                             tint: DS.Color.alert, action: endSession)
            }
            .padding(12)
        }
        .onAppear {
            camera.start()
            recorder.start()
            // A fence-mounted phone is never touched, so the idle timer WILL
            // fire mid-session - measured: screen off ~20s in, session dead.
            // Standard camera-app behavior: no auto-lock while running.
            // Restored on disappear so a forgotten app doesn't cook the
            // battery in a pocket.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .confirmationDialog("Save this session's video?",
                            isPresented: $askAboutRecording, titleVisibility: .visible) {
            Button("Save to camera roll") {
                if let url = finishedRecording {
                    SessionRecorder.saveToPhotos(url) { _ in onEnd() }
                } else { onEnd() }
            }
            Button("Discard", role: .destructive) {
                if let url = finishedRecording { SessionRecorder.discard(url) }
                onEnd()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // Record whatever ran, however the view was left.
            pipeline.session.finish(hadCourtMap: pipeline.calibration != nil)
        }
    }

    private func endSession() {
        pipeline.session.finish(hadCourtMap: pipeline.calibration != nil)
        camera.stop()
        recorder.finish { url in
            if let url {
                finishedRecording = url
                askAboutRecording = true    // leave the screen AFTER the choice
            } else {
                onEnd()
            }
        }
    }
}

/// A control that sits on top of live video: dark glass, hairline edge, small
/// uppercase label. Same family as the home screen's buttons, but quieter -
/// nothing here should compete with the overlay.
struct ChromeButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = DS.Color.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                }
                Text(title.uppercased())
                    .font(DS.Font.label)
                    .tracking(DS.Metric.labelTracking)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Color.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            )
        }
        .buttonStyle(PressScale())
    }
}

// MARK: - Overlay drawing

struct OverlayView: View {
    let result: FrameResult
    let calibration: Calibration?
    let ballRate: Double
    let ballRateBest: Double
    let videoSize: CGSize
    let viewSize: CGSize
    let fps: Double
    var flash: ContactFlash? = nil

    /// The window's safe-area insets. Read from the window rather than a
    /// GeometryReader because this overlay deliberately covers the whole
    /// display, so its own geometry reports no insets - and corner readouts
    /// placed without them land under the rounded corners and home indicator.
    private var safeInsets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: { $0.isKeyWindow })?.safeAreaInsets ?? .zero
    }

    var body: some View {
        Canvas { ctx, size in
            let fit = AspectFit(videoSize: videoSize, viewSize: size)

            drawCourtLines(ctx, fit)
            drawPlayers(ctx, fit)
            drawBall(ctx, fit)
            if let flash { drawContact(ctx, fit, size, flash) }
            drawMinimap(ctx, size)
            drawHUD(ctx)
        }
        .allowsHitTesting(false)
    }

    /// The contact: a bright border, the shot cone, the bisector (where the
    /// opponent should be) and a connector showing how far off it they were.
    private func drawContact(_ ctx: GraphicsContext, _ fit: AspectFit,
                             _ size: CGSize, _ flash: ContactFlash) {
        guard let cal = calibration else { return }
        func toView(_ court: CGPoint) -> CGPoint { fit.toView(cal.toImage(court)) }

        ctx.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)),
                   with: .color(.yellow), lineWidth: 12)

        let apex = toView(flash.apexCourt)
        let left = toView(flash.cone.left)
        let right = toView(flash.cone.right)
        let bis = toView(flash.cone.bisector)

        var wedge = Path()
        wedge.move(to: apex); wedge.addLine(to: left); wedge.addLine(to: right); wedge.closeSubpath()
        ctx.fill(wedge, with: .color(.purple.opacity(0.18)))
        for edge in [left, right] {
            var p = Path(); p.move(to: apex); p.addLine(to: edge)
            ctx.stroke(p, with: .color(.purple), lineWidth: 3)
        }
        var bisPath = Path(); bisPath.move(to: apex); bisPath.addLine(to: bis)
        ctx.stroke(bisPath, with: .color(.green), lineWidth: 2)

        if let reco = flash.recovery {
            let opp = fit.toView(reco.opponentPx)
            let ideal = toView(reco.idealCourt)
            let out = reco.meters > outOfPositionM
            let color: Color = out ? .red : .green
            var link = Path(); link.move(to: opp); link.addLine(to: ideal)
            ctx.stroke(link, with: .color(color),
                       style: StrokeStyle(lineWidth: 3, dash: out ? [] : [4, 4]))
            ctx.fill(Path(ellipseIn: CGRect(x: opp.x - 9, y: opp.y - 9, width: 18, height: 18)),
                     with: .color(color))
            ctx.draw(Text(String(format: "%.1fm off", reco.meters))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(color),
                     at: CGPoint(x: (opp.x + ideal.x) / 2 + 10, y: (opp.y + ideal.y) / 2),
                     anchor: .leading)
        }

        let ball = fit.toView(flash.ballPx)
        ctx.stroke(Path(ellipseIn: CGRect(x: ball.x - 16, y: ball.y - 16, width: 32, height: 32)),
                   with: .color(.yellow), lineWidth: 3)
    }

    // Reproject the court outline (court meters -> image pixels -> view).
    private func drawCourtLines(_ ctx: GraphicsContext, _ fit: AspectFit) {
        guard let cal = calibration else { return }
        var path = Path()
        for (a, b) in Court.courtSegments {
            let pa = fit.toView(cal.toImage(a))
            let pb = fit.toView(cal.toImage(b))
            path.move(to: pa); path.addLine(to: pb)
        }
        // Thick and bright orange. The 2px 70% yellow was invisible against
        // sunlit paint from across a court - the overlay exists to be read at
        // a glance from the baseline.
        ctx.stroke(path, with: .color(.orange), lineWidth: 8)
    }

    private func drawPlayers(_ ctx: GraphicsContext, _ fit: AspectFit) {
        for p in result.players {
            let box = CGRect(origin: fit.toView(p.boxPx.origin),
                             size: CGSize(width: p.boxPx.width * fit.scale,
                                          height: p.boxPx.height * fit.scale))
            ctx.stroke(Path(box), with: .color(.green), lineWidth: 2)

            let foot = fit.toView(p.footPx)
            ctx.fill(Path(ellipseIn: CGRect(x: foot.x - 4, y: foot.y - 4, width: 8, height: 8)),
                     with: .color(.red))

            let label = String(format: "#%d  (%.1f, %.1f)m", p.id, p.courtPos.x, p.courtPos.y)
            ctx.draw(Text(label).font(.caption2).foregroundStyle(.green),
                     at: CGPoint(x: box.minX + 4, y: box.minY - 8), anchor: .bottomLeading)
        }
    }

    private func drawBall(_ ctx: GraphicsContext, _ fit: AspectFit) {
        guard let ball = result.ballPx else { return }
        let p = fit.toView(ball)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                 with: .color(.yellow))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                   with: .color(.black), lineWidth: 1)
    }

    // Top-down minimap in the bottom-right corner.
    private func drawMinimap(_ ctx: GraphicsContext, _ size: CGSize) {
        // Sized to the view (~28% of height) rather than a fixed 200pt, which
        // swallowed over half the height of a landscape phone.
        //
        // The box is the DOUBLES court (10.97m wide), not the singles one. That
        // is what fixes the sliver: singles is 8.23 x 23.77m, a 1:2.9 shape,
        // while doubles is 1:2.2 - a third wider, and still exactly true to a
        // real court. The singles sidelines are drawn inside it. Stretching the
        // singles box to taste would have been the other way to widen it, but
        // this readout exists to judge whether a player's position looks right,
        // and a distorted plan view cannot do that.
        let mapHalfWidthM = CourtDetect.doublesHalfWidthM
        let mh: CGFloat = min(150, max(90, size.height * 0.28))
        let mw: CGFloat = mh * CGFloat(2 * mapHalfWidthM / Court.lengthM)
        // Inset by the SAFE AREA, not a fixed 16pt. This canvas covers the whole
        // display (the preview fills it), so the bottom-right corner is under
        // the screen's rounded corner and, in landscape, the home indicator -
        // which is what was clipping the court icon. safeInsets comes from the
        // window, because this view ignores safe areas and its GeometryReader
        // therefore reports zero.
        let pad: CGFloat = 12
        let origin = CGPoint(x: size.width - mw - safeInsets.right - pad,
                             y: size.height - mh - safeInsets.bottom - pad)
        let rect = CGRect(origin: origin, size: CGSize(width: mw, height: mh))

        ctx.fill(Path(rect), with: .color(.black.opacity(0.45)))
        ctx.stroke(Path(rect), with: .color(.white.opacity(0.8)), lineWidth: 1.5)

        func toMap(_ court: CGPoint) -> CGPoint {
            let x = (court.x + CGFloat(mapHalfWidthM)) / CGFloat(2 * mapHalfWidthM)
            let y = court.y / CGFloat(Court.lengthM)
            return CGPoint(x: origin.x + x * mw, y: origin.y + (1 - y) * mh) // far side at top
        }
        // Singles sidelines, inside the doubles box.
        for x in [-Court.halfWidthM, Court.halfWidthM] {
            var side = Path()
            side.move(to: toMap(CGPoint(x: x, y: 0)))
            side.addLine(to: toMap(CGPoint(x: x, y: Court.lengthM)))
            ctx.stroke(side, with: .color(.white.opacity(0.55)), lineWidth: 1)
        }
        // The NET reads as the divider it is; the service lines are secondary.
        // They were all the same weight before, which is what made this look
        // like four anonymous boxes rather than a court.
        // The net spans the full doubles width; service lines stop at the
        // singles sidelines, as they do on a real court.
        for (yLine, halfW, alpha, width) in
            [(Court.netY, mapHalfWidthM, 0.95, 1.6),
             (Court.farServiceLineY, Court.halfWidthM, 0.4, 0.8),
             (Court.nearServiceLineY, Court.halfWidthM, 0.4, 0.8)] {
            let a = toMap(CGPoint(x: -halfW, y: yLine))
            let b = toMap(CGPoint(x:  halfW, y: yLine))
            var path = Path(); path.move(to: a); path.addLine(to: b)
            ctx.stroke(path, with: .color(.white.opacity(alpha)), lineWidth: width)
        }
        // Center service line, so the halves read as service boxes.
        var center = Path()
        center.move(to: toMap(CGPoint(x: 0, y: Court.nearServiceLineY)))
        center.addLine(to: toMap(CGPoint(x: 0, y: Court.farServiceLineY)))
        ctx.stroke(center, with: .color(.white.opacity(0.4)), lineWidth: 0.8)

        // Players (red) + ball (yellow).
        for p in result.players {
            let m = toMap(p.courtPos)
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - 4, y: m.y - 4, width: 8, height: 8)),
                     with: .color(.red))
        }
        if let bc = result.ballCourt {
            let m = toMap(bc)
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - 3, y: m.y - 3, width: 6, height: 6)),
                     with: .color(.yellow))
        }
    }

    private func drawHUD(_ ctx: GraphicsContext) {
        let text = String(format: "%.0f fps · %.0f ms · %d players · BALL %.0f%%%@",
                          fps, result.latencyMs, result.players.count,
                          ballRate * 100,
                          ballRateBest > 0 ? String(format: " (best %.0f%%)", ballRateBest * 100) : "")
        // GraphicsContext.draw only takes a plain Text, so draw the pill
        // background ourselves, then the resolved text on top.
        let resolved = ctx.resolve(Text(text).font(.caption.monospaced()).foregroundStyle(.white))
        let size = resolved.measure(in: CGSize(width: 500, height: 100))
        let origin = CGPoint(x: 12, y: 12)
        let bg = CGRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 6)
        ctx.fill(Path(roundedRect: bg, cornerRadius: 5), with: .color(.black.opacity(0.5)))
        ctx.draw(resolved, at: CGPoint(x: origin.x + 5, y: origin.y + 3), anchor: .topLeading)
    }
}
