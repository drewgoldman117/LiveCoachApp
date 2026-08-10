// BuzzerPairingView.swift
//
// Pair the Shelly BLU buzzer, once. Reached from the home screen's BUZZER row.
//
// The instruction to press the button is the whole screen, not a footnote: a
// sleeping Shelly is INVISIBLE to a scan (measured - a 60s scan found nothing
// until it was pressed), so a user who doesn't press it sees an empty list and
// concludes the app is broken. Same reason the list says what it's waiting for
// rather than just spinning.

import SwiftUI

struct BuzzerPairingView: View {
    @ObservedObject var buzzer: BuzzerLink
    let onDone: () -> Void

    var body: some View {
        ZStack {
            DS.Color.surface.ignoresSafeArea()

            HStack(alignment: .top, spacing: DS.Metric.gutter) {
                instructions
                deviceList.frame(width: 320)
            }
            .padding(.horizontal, DS.Metric.pagePadding)
            .padding(.vertical, 12)
        }
        .onAppear { buzzer.startScan() }
        .onDisappear { buzzer.stopScan() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "pair your buzzer")
                Spacer()
                ChromeButton(title: "done", tint: DS.Color.textSecondary, action: onDone)
            }
            Hairline()

            // Stays imperative through the CONNECT too, not just the scan. The
            // Shelly falls asleep within seconds, and an iOS connect only
            // completes while the device is connectable - so tapping it in the
            // list is not the end of the job, it's the middle. Saying "pairing…"
            // and going quiet is what made this look stuck.
            // HOLD, not press. Shelly's own BLE docs: "Connection is only
            // possible from a paired devices, or if pairing mode is active."
            // A short press merely wakes the BTHome beacon - the device then
            // advertises, appears in a scan, and still refuses the connection,
            // which is exactly the "visible but never connects" dead end. The
            // 10-second hold is the only way in for a device it doesn't know.
            Text(buzzer.state == .connected ? "Paired." : "Hold the button for 10 seconds.")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)

            Text("Hold it until the light flashes — that's pairing mode, and it lasts about "
                 + "a minute. A short press only wakes it up: it will appear here and still "
                 + "refuse to connect, because a Shelly only accepts connections from a "
                 + "device it's already paired with, or while pairing mode is active.")
                .font(.system(size: 12))
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("iOS will ask you to confirm the pairing the first time.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textTertiary)

            // The confirmation you can hear. The phone ends up on a fence, so
            // "did it actually pair?" has to be answerable from the baseline
            // without walking over to read a screen.
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Color.positive)
                Text("The buzzer beeps 3 times fast when it's paired and ready.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)


            Spacer()

            if buzzer.state == .connected {
                HStack(spacing: 10) {
                    StatusChip(text: "connected", tint: DS.Color.positive, live: true)
                    SecondaryButton(title: "test beep", systemImage: "speaker.wave.2.fill") {
                        buzzer.buzz()
                    }
                    .frame(width: 150)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deviceList: some View {
        Panel(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "found")
                    Spacer()
                    if buzzer.isScanning {
                        ProgressView().controlSize(.mini).tint(DS.Color.textTertiary)
                    }
                }
                Hairline()

                if buzzer.state == .unauthorized {
                    Text("Bluetooth is off or not permitted for this app.")
                        .font(DS.Font.value)
                        .foregroundStyle(DS.Color.alert)
                } else if buzzer.discovered.isEmpty {
                    Text("Nothing yet — press the button.")
                        .font(DS.Font.value)
                        .foregroundStyle(DS.Color.textTertiary)
                } else {
                    ForEach(buzzer.discovered) { d in
                        Button { buzzer.pair(d) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.name)
                                        .font(DS.Font.value)
                                        .foregroundStyle(DS.Color.textPrimary)
                                    Text("\(d.rssi) dBm")
                                        .font(DS.Font.caption)
                                        .foregroundStyle(DS.Color.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(DS.Color.accent)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
