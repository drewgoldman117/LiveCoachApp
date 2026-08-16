// LiveCoachApp.swift — app entry point.

import SwiftUI
import Sentry

@main
struct LiveCoachApp: App {
    init() {
        // Crash reporting. The point is the field: the app dying at the court
        // with no Mac attached currently leaves no evidence at all, and a
        // session that ends in a silent crash looks identical to one the user
        // ended. The DSN lives in Info.plist (set in project.yml); empty means
        // disabled, so builds keep working before the Sentry project exists.
        if let dsn = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String,
           !dsn.isEmpty {
            SentrySDK.start { options in
                options.dsn = dsn
                // Crashes and errors only. No performance tracing: this app
                // runs two ML models at 60fps, and profiling overhead lands
                // directly on the frame budget.
                options.tracesSampleRate = 0
                options.enableAppHangTracking = false
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
