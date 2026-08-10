// ContentView.swift
//
// Top-level flow. The home screen is the root: it reports what the system knows
// (court map, models, last session) and offers the one way in. From there you
// either start a session or calibrate the court.
//
// Home is the root even on a fresh install, where it shows "no court map" and
// makes CALIBRATE the primary action. Dropping straight into the calibration
// screen - which is what this used to do - gave a first-launch user a live
// camera and eight taps to make with no idea what the app was.

import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    /// Owned here, not by HomeView: the link has to survive navigation into a
    /// session, which is the whole point of holding it open.
    @StateObject private var buzzer = BuzzerLink()
    @State private var calibration: Calibration? = Calibration.load()
    @State private var screen: Screen = .home
    /// Bumped whenever the calibration changes, to re-mount LiveView (and its
    /// detection pipeline) against the new court map.
    @State private var calibrationVersion = 0

    private enum Screen { case home, live, calibrate }

    var body: some View {
        ZStack {
            DS.Color.surface.ignoresSafeArea()

            switch screen {
            case .home:
                HomeView(calibration: calibration,
                         onStart: { screen = .live },
                         onCalibrate: { screen = .calibrate },
                         buzzer: buzzer)
                    .transition(.opacity)

            case .calibrate:
                CalibrationView(camera: camera) { newCal in
                    calibration = newCal
                    calibrationVersion += 1
                    screen = .home
                } onCancel: {
                    screen = .home
                }

            case .live:
                LiveView(camera: camera,
                         calibration: calibration,
                         buzzer: buzzer,
                         onEnd: { screen = .home })
                    .id(calibrationVersion)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: screen)
        .statusBarHidden(true)
        // Leaving either camera screen should release the camera; the home
        // screen has no preview, so a running session would just drain battery.
        .onChange(of: screen) { _, newValue in
            if newValue == .home { camera.stop() }
        }
    }
}
