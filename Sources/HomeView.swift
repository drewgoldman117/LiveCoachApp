// HomeView.swift
//
// The screen you land on: what the system knows right now, and one way in.
//
// Landscape, because the whole app is (the phone lives zip-tied to a fence in
// landscape), so this is a two-column layout rather than a stacked one: the
// signal diagram on the left, machine state and the action on the right.
//
// Everything in the status column is MEASURED, not decorative - saved court
// map, last session, whether the Core ML models are actually in the bundle.
// Anything the app can't yet know says so plainly (the buzzer isn't ported);
// a fake number here would undermine every real one next to it.

import SwiftUI

struct HomeView: View {
    let calibration: Calibration?
    let onStart: () -> Void
    let onCalibrate: () -> Void
    @ObservedObject var buzzer: BuzzerLink

    @State private var lastSession = SessionRecord.load()
    @State private var pairing = false

    /// What the BUZZER row says, and whether it's an invitation to act.
    private var buzzerStatus: (text: String, tint: Color) {
        switch buzzer.state {
        case .connected:        return ("ready", DS.Color.positive)
        case .waitingForDevice: return ("press the button", DS.Color.accent)
        case .unauthorized:     return ("bluetooth off", DS.Color.alert)
        case .unpaired:         return ("tap to pair", DS.Color.textTertiary)
        }
    }

    private var hasCourt: Bool { calibration != nil }

    /// The models are compiled into the bundle at build time; if they're missing
    /// the live view can only show a camera image, so it's worth saying up front
    /// rather than after tapping start.
    private var modelsReady: Bool {
        Bundle.main.url(forResource: "PlayerDetector", withExtension: "mlmodelc") != nil &&
        Bundle.main.url(forResource: "BallDetector", withExtension: "mlmodelc") != nil
    }

    /// Modification date of calibration.json - when this court map was made.
    private var courtSavedAt: Date? {
        try? FileManager.default
            .attributesOfItem(atPath: Calibration.fileURL.path)[.modificationDate] as? Date
    }

    var body: some View {
        ZStack {
            DS.Color.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Hairline().padding(.top, 10)

                HStack(alignment: .top, spacing: DS.Metric.gutter) {
                    signalPanel
                    statusColumn.frame(width: 290)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, DS.Metric.pagePadding)
            .padding(.vertical, 10)
        }
        .onAppear {
            lastSession = SessionRecord.load()
            // Re-attach to a remembered button. The connect sits pending, so
            // this costs nothing until the user presses it.
            buzzer.connectSaved()
        }
        .sheet(isPresented: $pairing) {
            BuzzerPairingView(buzzer: buzzer) { pairing = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LIVECOACH")
                    .font(DS.Font.wordmark)
                    .tracking(DS.Metric.wordmarkTracking)
                    .foregroundStyle(DS.Color.textPrimary)
                Text("on-device positioning coach")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            Spacer()
            // ONE chip, answering the only question worth asking here: can I hit
            // start and have this work? It reports the most actionable fact,
            // worst first, so it always says something that changes what you do
            // next. The chips it replaced didn't: "models ready" is the normal
            // case (permanent decoration) and "finds court on start" described
            // how the app works rather than any state.
            StatusChip(text: readiness.text, tint: readiness.tint,
                       filled: readiness.filled, live: readiness.live)
        }
    }

    /// Worst-first: a blocker beats a degraded state beats "good to go".
    private var readiness: (text: String, tint: Color, filled: Bool, live: Bool) {
        if !modelsReady {
            // Nothing works without these - no players, no ball, no alerts.
            return ("models missing", DS.Color.alert, true, false)
        }
        switch buzzer.state {
        case .unauthorized:
            return ("bluetooth off", DS.Color.alert, true, false)
        case .connected:
            return ("ready to play", DS.Color.positive, true, true)
        case .waitingForDevice:
            // Say what to DO, not what the software is doing. The connect is
            // pending and only completes while the Shelly is awake, so the user
            // pressing it is the missing step - "waking" described the device
            // and left that unsaid.
            return ("press buzzer button", DS.Color.accent, false, true)
        case .unpaired:
            // Tracking still works and the session still records; you just get
            // no beep on court, so this is a caveat and not an error.
            return ("ready · no buzzer", DS.Color.textSecondary, false, false)
        }
    }

    // MARK: - Left: the signal

    private var signalPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "the signal")
                    Spacer()
                    Text("cochet, theory of angles")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
                }
                CourtDiagram()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("When your opponent strikes, the bisector of their shot cone is where "
                     + "you should be standing. You get buzzed the moment you aren't.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right: state + action

    private var statusColumn: some View {
        VStack(spacing: 8) {
            // One panel, two groups. Separate panels for these overflowed the
            // landscape height and clipped the buttons off the bottom - vertical
            // space is the scarce resource on this screen, not horizontal.
            //
            // Scrollable so the ACTION never gets pushed off: on a large phone
            // it never scrolls and looks identical, on a small one (SE in
            // landscape is only ~320pt tall) the readout scrolls instead of the
            // buttons disappearing.
            ScrollView {
                Panel(padding: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionLabel(text: "status")
                        Hairline()
                        // Never "not calibrated" in alert red: having no saved
                        // map is no longer a problem to fix, it is just the
                        // first run. The session finds the court itself and
                        // re-finds it if the phone is knocked, so this row
                        // reports what's remembered, not what's missing.
                        StatRow(key: "court",
                                value: hasCourt
                                    ? (courtSavedAt.map { "found \(Fmt.ago($0))" } ?? "found")
                                    : "found when you start",
                                tint: hasCourt ? DS.Color.textPrimary : DS.Color.textSecondary)
                        StatRow(key: "capture", value: "1080p · 60 fps · ANE")
                        // Tappable: this row is the way into pairing, and it's
                        // also where "press the button" surfaces mid-session.
                        Button { pairing = true } label: {
                            StatRow(key: "buzzer", value: buzzerStatus.text,
                                    tint: buzzerStatus.tint)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())

                        SectionLabel(text: "last session").padding(.top, 3)
                        Hairline()
                        if let s = lastSession {
                            StatRow(key: "when", value: Fmt.ago(s.endedAt))
                            StatRow(key: "ran for", value: Fmt.duration(s.duration))
                            StatRow(key: "avg fps", value: String(format: "%.0f", s.avgFPS),
                                    tint: s.avgFPS >= 25 ? DS.Color.textPrimary : DS.Color.alert)
                        } else {
                            Text("none yet")
                                .font(DS.Font.value)
                                .foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)

            // Starting is the ONLY action: the session finds the court itself
            // (LiveCourt) and re-finds it if the phone is knocked, so there is
            // nothing to calibrate by hand. Manual calibration was removed
            // entirely rather than kept as a fallback - offering it implies the
            // automatic path can't be trusted, and it is the path that works.
            PrimaryButton(title: "start session", systemImage: "play.fill", action: onStart)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - The court diagram
//
// A drawn court in perspective with the shot cone, its bisector, and an
// opponent standing off it. Not live data - it's the diagram of what the system
// computes, which is why the panel is labelled "the signal" rather than dressed
// up as a readout.

struct CourtDiagram: View {
    @State private var pulse = false

    /// Synthetic perspective: a camera behind the near baseline. `k` sets how
    /// hard the far end compresses; both the width scale and the depth position
    /// come from the same projective term, so the trapezoid is consistent.
    private func project(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        let k = 1.35
        let t = p.y / Court.lengthM
        let s = 1.0 / (1.0 + k * t)
        let f = t * (1.0 + k) * s
        let x = rect.midX + (p.x / Court.halfWidthM) * (rect.width * 0.46) * s
        let y = rect.maxY - f * rect.height
        return CGPoint(x: x, y: y)
    }

    // The illustrated moment: your OPPONENT strikes from the left corner, so the
    // cone (and its bisector) swings right - and you are the one caught off it.
    // The camera sits behind their baseline, which is what makes you the far
    // player whose position is measured.
    private let apex = CGPoint(x: -3.1, y: 1.2)
    private let coneLeft = CGPoint(x: -Court.halfWidthM, y: Court.farServiceLineY)
    private let coneRight = CGPoint(x: Court.halfWidthM, y: Court.farServiceLineY)
    private let opponent = CGPoint(x: -3.2, y: 20.1)

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            func P(_ p: CGPoint) -> CGPoint { project(p, in: rect) }

            // --- surface ---
            var court = Path()
            court.move(to: P(CGPoint(x: -Court.halfWidthM, y: 0)))
            court.addLine(to: P(CGPoint(x: Court.halfWidthM, y: 0)))
            court.addLine(to: P(CGPoint(x: Court.halfWidthM, y: Court.lengthM)))
            court.addLine(to: P(CGPoint(x: -Court.halfWidthM, y: Court.lengthM)))
            court.closeSubpath()
            ctx.fill(court, with: .color(Color.white.opacity(0.035)))

            // --- the shot cone, filled then edged ---
            var cone = Path()
            cone.move(to: P(apex))
            cone.addLine(to: P(coneLeft))
            cone.addLine(to: P(coneRight))
            cone.closeSubpath()
            ctx.fill(cone, with: .linearGradient(
                Gradient(colors: [DS.Color.accent.opacity(0.20), DS.Color.accent.opacity(0.04)]),
                startPoint: P(apex), endPoint: P(coneRight)))
            for edge in [coneLeft, coneRight] {
                var e = Path(); e.move(to: P(apex)); e.addLine(to: P(edge))
                ctx.stroke(e, with: .color(DS.Color.accent.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // --- court lines (far ones dimmer: depth without extra colour) ---
            for (a, b) in Court.courtSegments {
                var seg = Path(); seg.move(to: P(a)); seg.addLine(to: P(b))
                let depth = max(a.y, b.y) / Court.lengthM
                ctx.stroke(seg, with: .color(Color.white.opacity(0.38 - 0.14 * depth)),
                           lineWidth: 1)
            }
            // Net: the one heavier line, since it's what the ball has to clear.
            var net = Path()
            net.move(to: P(CGPoint(x: -Court.halfWidthM, y: Court.netY)))
            net.addLine(to: P(CGPoint(x: Court.halfWidthM, y: Court.netY)))
            ctx.stroke(net, with: .color(Color.white.opacity(0.55)), lineWidth: 2)

            // --- the bisector: the ideal recovery line, and the hero of the image ---
            let bisectorEnd = CGPoint(x: (coneLeft.x + coneRight.x) / 2 + 0.9, y: Court.lengthM)
            var bis = Path(); bis.move(to: P(apex)); bis.addLine(to: P(bisectorEnd))
            ctx.stroke(bis, with: .color(DS.Color.accent.opacity(0.30)), lineWidth: 5)   // glow
            ctx.stroke(bis, with: .color(DS.Color.accent), lineWidth: 1.6)

            // --- you (at the apex) ---
            let a = P(apex)
            ctx.fill(Path(ellipseIn: CGRect(x: a.x - 4, y: a.y - 4, width: 8, height: 8)),
                     with: .color(DS.Color.accent))

            // --- the opponent, and how far off the line they are ---
            let o = P(opponent)
            let onLine = closestPointOnBisector(apex: apex, end: bisectorEnd, to: opponent)
            let f = P(onLine)
            var connector = Path(); connector.move(to: o); connector.addLine(to: f)
            ctx.stroke(connector, with: .color(DS.Color.alert.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            ctx.stroke(Path(ellipseIn: CGRect(x: o.x - 5, y: o.y - 5, width: 10, height: 10)),
                       with: .color(DS.Color.alert), lineWidth: 2)

            let metres = hypot(opponent.x - onLine.x, opponent.y - onLine.y)
            // Left of the connector, not above it: above collided with the far
            // baseline and the panel edge.
            ctx.draw(Text(String(format: "%.1f m off", metres))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.alert),
                     at: CGPoint(x: min(o.x, f.x) - 8, y: (o.y + f.y) / 2), anchor: .trailing)
        }
        // One slow breath on the whole diagram - enough to feel live, not enough
        // to distract or cost battery.
        .opacity(pulse ? 1.0 : 0.88)
        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }

    /// Foot of the perpendicular from `p` to the bisector - the same computation
    /// as `bisector_offset` in the Python prototype, in court metres.
    private func closestPointOnBisector(apex: CGPoint, end: CGPoint, to p: CGPoint) -> CGPoint {
        let d = CGPoint(x: end.x - apex.x, y: end.y - apex.y)
        let l2 = d.x * d.x + d.y * d.y
        guard l2 > 0 else { return apex }
        let t = ((p.x - apex.x) * d.x + (p.y - apex.y) * d.y) / l2
        return CGPoint(x: apex.x + t * d.x, y: apex.y + t * d.y)
    }
}
