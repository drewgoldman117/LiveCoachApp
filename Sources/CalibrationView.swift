// CalibrationView.swift
//
// On-device equivalent of calibrate.py: tap the known court landmarks on the
// live camera image, in the order Court.cornerLabels lists them (far baseline
// L/R, far service line L/R, net L/R, near baseline L/R). Fits a least-squares
// homography and saves it. Tap on the LIVE preview -- the court is static, so
// there's no need to freeze a frame.
//
// Place all 8 if your baseline is visible; if the phone is mounted right behind
// your own baseline and can't see it, place just the first 6 (drop the near
// baseline pair) and Save -- the tactical goal only needs the far half.

import SwiftUI

struct CalibrationView: View {
    @ObservedObject var camera: CameraManager
    var onDone: (Calibration) -> Void
    /// Back to the home screen without saving. Needed because home - not this
    /// screen - is now the app's root, so calibration has to be escapable.
    var onCancel: (() -> Void)? = nil

    @State private var points: [CGPoint] = []   // in frame-pixel coords
    @State private var errorText: String?

    private var total: Int { Court.corners.count }

    var body: some View {
        GeometryReader { geo in
            let fit = AspectFit(videoSize: camera.videoSize, viewSize: geo.size)
            ZStack {
                CameraPreview(session: camera.session, angle: camera.captureAngle)

                Canvas { ctx, _ in
                    // Placed points + numbers.
                    for (i, fp) in points.enumerated() {
                        let v = fit.toView(fp)
                        ctx.fill(Path(ellipseIn: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)),
                                 with: .color(.green))
                        ctx.draw(Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.green),
                                 at: CGPoint(x: v.x + 12, y: v.y - 12))
                    }
                    // Connect line pairs + sideline chains as they get placed.
                    drawGuides(ctx, fit)
                }
                .allowsHitTesting(false)

                // Tap capture (DragGesture with 0 distance gives us a location).
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard points.count < total else { return }
                        points.append(fit.toFrame(value.location))
                    })
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) { promptBar }
            .overlay(alignment: .bottom) { controls }
        }
        .onAppear { camera.start() }
    }

    private var promptBar: some View {
        HStack(spacing: 10) {
            // Progress as a count of filled pips: how many taps are left is the
            // one thing you want to know without reading.
            HStack(spacing: 3) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i < points.count ? DS.Color.accent : Color.white.opacity(0.25))
                        .frame(width: i < points.count ? 10 : 6, height: 3)
                }
            }
            Text(points.count < total
                 ? Court.cornerLabels[points.count].uppercased()
                 : "ALL POINTS PLACED — SAVE, OR UNDO TO ADJUST")
                .font(DS.Font.label)
                .tracking(DS.Metric.labelTracking)
                .foregroundStyle(DS.Color.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            Capsule().fill(Color.black.opacity(0.65))
                .overlay(Capsule().strokeBorder(DS.Color.hairline, lineWidth: 1))
        )
        .padding(.top, 12)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if let errorText {
                Text(errorText)
                    .font(DS.Font.caption).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(DS.Color.alert))
            }
            HStack(spacing: 10) {
                if let onCancel {
                    ChromeButton(title: "cancel", systemImage: "xmark",
                                 tint: DS.Color.textSecondary, action: onCancel)
                }
                ChromeButton(title: "undo", systemImage: "arrow.uturn.backward") {
                    if !points.isEmpty { points.removeLast() }
                }
                .opacity(points.isEmpty ? 0.35 : 1)
                .disabled(points.isEmpty)

                ChromeButton(title: "reset") { points.removeAll() }
                    .opacity(points.isEmpty ? 0.35 : 1)
                    .disabled(points.isEmpty)

                // 6 (far half) or 8; 4 fits but is fragile.
                ChromeButton(title: "save court", systemImage: "checkmark",
                             tint: DS.Color.accent) { save() }
                    .opacity(points.count < 6 ? 0.35 : 1)
                    .disabled(points.count < 6)
            }
        }
        .padding(.bottom, 16)
    }

    private func drawGuides(_ ctx: GraphicsContext, _ fit: AspectFit) {
        for (a, b) in Court.linePairs where points.count > b {
            var path = Path()
            path.move(to: fit.toView(points[a])); path.addLine(to: fit.toView(points[b]))
            ctx.stroke(path, with: .color(.yellow.opacity(0.8)), lineWidth: 2)
        }
        for chain in Court.sidelineChains {
            let placed = chain.filter { $0 < points.count }
            guard placed.count > 1 else { continue }
            var path = Path()
            path.move(to: fit.toView(points[placed[0]]))
            for i in 1..<placed.count { path.addLine(to: fit.toView(points[placed[i]])) }
            ctx.stroke(path, with: .color(.yellow.opacity(0.8)), lineWidth: 2)
        }
    }

    private func save() {
        guard let cal = Calibration.fit(imagePoints: points,
                                        frameWidth: Int(camera.videoSize.width),
                                        frameHeight: Int(camera.videoSize.height)) else {
            errorText = "Could not fit a homography from those points — try Reset."
            return
        }
        do {
            try cal.save()
            onDone(cal)
        } catch {
            errorText = "Saved fit but failed to write file: \(error.localizedDescription)"
        }
    }
}
