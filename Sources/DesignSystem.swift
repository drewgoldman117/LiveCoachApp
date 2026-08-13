// DesignSystem.swift
//
// The app's visual language, in one file. Direction: broadcast/instrument HUD -
// near-black surfaces, hairline rules, monospaced numerals, and a single
// yellow-green accent used only for the things that matter (the primary action,
// the bisector beam, a live indicator). It is deliberately the same vocabulary
// as the live overlay, so the home screen and the camera view read as one
// instrument rather than two apps.
//
// Rules that keep it coherent:
//   - ONE accent. If everything is highlighted, nothing is.
//   - Numbers and machine state are monospaced; prose is not.
//   - Labels are uppercase, small, wide-tracked, and secondary-colored.
//   - Structure comes from hairlines and space, never from heavy borders.

import SwiftUI

enum DS {

    // MARK: - Color

    enum Color {
        /// Page background. Near-black with a trace of blue so it doesn't read as flat ink.
        static let surface = SwiftUI.Color(red: 0.043, green: 0.051, blue: 0.059)
        /// Panels sitting on the surface.
        static let raised = SwiftUI.Color(red: 0.071, green: 0.082, blue: 0.094)
        /// Hairline rules and panel edges.
        static let hairline = SwiftUI.Color.white.opacity(0.10)

        static let textPrimary = SwiftUI.Color(red: 0.949, green: 0.961, blue: 0.965)
        static let textSecondary = SwiftUI.Color(red: 0.541, green: 0.573, blue: 0.600)
        static let textTertiary = SwiftUI.Color(red: 0.361, green: 0.388, blue: 0.412)

        /// THE accent: tennis-ball yellow-green. Used for the primary action, the
        /// bisector beam, and live state - nothing else.
        static let accent = SwiftUI.Color(red: 0.847, green: 1.0, blue: 0.243)
        /// Out of position / stop. Matches the live overlay's red foot dots.
        static let alert = SwiftUI.Color(red: 1.0, green: 0.290, blue: 0.239)
        static let positive = SwiftUI.Color(red: 0.275, green: 0.878, blue: 0.541)
    }

    // MARK: - Type
    //
    // Two families only: monospaced for machine state (fps, meters, timings,
    // labels), the system face for headings and prose.

    enum Font {
        /// The wordmark: wide-tracked uppercase, the one piece of "brand" here.
        static let wordmark = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// Section labels: SESSION, COURT, HARDWARE.
        static let label = SwiftUI.Font.system(size: 10, weight: .semibold, design: .monospaced)
        /// Row keys inside a panel.
        static let key = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
        /// Row values - monospaced so digits don't jitter as they update.
        static let value = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
        /// Big readouts.
        static let readout = SwiftUI.Font.system(size: 26, weight: .semibold, design: .monospaced)
        static let button = SwiftUI.Font.system(size: 14, weight: .bold)
        static let caption = SwiftUI.Font.system(size: 10, weight: .regular, design: .monospaced)
    }

    // MARK: - Metrics

    enum Metric {
        // Sized for the SHORT side: landscape on an iPhone gives ~400pt of
        // height, and the whole home screen has to fit inside it without
        // scrolling. Generous padding is the first thing that breaks that.
        static let pagePadding: CGFloat = 18
        static let gutter: CGFloat = 16
        static let panelRadius: CGFloat = 10
        static let controlHeight: CGFloat = 46
        /// Tracking used on every uppercase label - the thing that makes small
        /// caps read as instrument labeling rather than shouting.
        static let labelTracking: CGFloat = 1.6
        static let wordmarkTracking: CGFloat = 4.5
    }
}

// MARK: - Components

/// An uppercase section label above a group of rows.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.label)
            .tracking(DS.Metric.labelTracking)
            .foregroundStyle(DS.Color.textTertiary)
    }
}

/// A 1px rule. Structure without weight.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(DS.Color.hairline)
            .frame(height: 1)
    }
}

/// A key/value row: monospaced key on the left, value right-aligned so a column
/// of them lines up like a readout.
struct StatRow: View {
    let key: String
    let value: String
    var tint: Color = DS.Color.textPrimary
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key.uppercased())
                .font(DS.Font.key)
                .tracking(DS.Metric.labelTracking)
                .foregroundStyle(DS.Color.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(DS.Font.value)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Small status chip: a dot plus a word. `live` slowly pulses, which is the only
/// motion in the header - it reads as a running instrument.
struct StatusChip: View {
    let text: String
    var tint: Color = DS.Color.positive
    var filled: Bool = true
    var live: Bool = false

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .strokeBorder(tint, lineWidth: filled ? 0 : 1)
                .background(Circle().fill(filled ? tint : .clear))
                .frame(width: 6, height: 6)
                .opacity(live && pulse ? 0.25 : 1)
                .animation(live ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                                : .default,
                           value: pulse)
            Text(text.uppercased())
                .font(DS.Font.label)
                .tracking(DS.Metric.labelTracking)
                .foregroundStyle(filled ? DS.Color.textPrimary : DS.Color.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(DS.Color.raised)
                .overlay(Capsule().strokeBorder(DS.Color.hairline, lineWidth: 1))
        )
        .onAppear { if live { pulse = true } }
    }
}

/// A panel: raised surface, hairline edge, generous inner padding.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DS.Metric.panelRadius, style: .continuous)
                    .fill(DS.Color.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Metric.panelRadius, style: .continuous)
                            .strokeBorder(DS.Color.hairline, lineWidth: 1)
                    )
            )
    }
}

/// The one loud element on the screen: the primary action, in accent, with the
/// label wide-tracked. `destructive` swaps the accent for alert red (END SESSION).
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var destructive: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    private var tint: Color { destructive ? DS.Color.alert : DS.Color.accent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .bold))
                }
                Text(title.uppercased())
                    .font(DS.Font.button)
                    .tracking(DS.Metric.labelTracking)
            }
            .foregroundStyle(destructive ? Color.white : DS.Color.surface)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Metric.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Metric.panelRadius, style: .continuous)
                    .fill(tint)
            )
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
    }
}

/// Quiet action: hairline outline, no fill.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title.uppercased())
                    .font(DS.Font.label)
                    .tracking(DS.Metric.labelTracking)
            }
            .foregroundStyle(DS.Color.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DS.Color.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(PressScale())
    }
}

/// Every control uses the same press feedback: a small, fast scale. Consistency
/// in motion is as much a part of the system as the colors.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
