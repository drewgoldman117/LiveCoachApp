// SessionLog.swift
//
// A one-record log of the last live session, so the home screen can report
// something true instead of a decorative number. Written when the live view is
// dismissed, read when the home screen appears.
//
// Deliberately minimal: only what the app actually measures today (duration,
// frames, average fps, whether a court map was in use). Contact and alert counts
// belong here too, but contact detection isn't ported yet - see the Python
// repo's CLAUDE.md - and inventing those figures would make the panel a
// decoration rather than an instrument.

import Foundation

struct SessionRecord: Codable {
    var endedAt: Date
    var duration: TimeInterval
    var frames: Int
    var avgFPS: Double
    var hadCourtMap: Bool

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("last_session.json")
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: SessionRecord.fileURL, options: .atomic)
    }

    static func load() -> SessionRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }
}

/// Accumulates a session while it runs. Owned by the live view.
final class SessionTracker {
    private let startedAt = Date()
    private var frames = 0
    private var fpsSum = 0.0

    func tick(fps: Double) {
        frames += 1
        fpsSum += fps
    }

    /// Persist the session. Sub-second sessions are dropped - tapping start and
    /// immediately backing out isn't a session, and recording it would wipe the
    /// previous real one.
    @discardableResult
    func finish(hadCourtMap: Bool) -> SessionRecord? {
        let duration = Date().timeIntervalSince(startedAt)
        guard duration >= 1, frames > 0 else { return nil }
        let record = SessionRecord(endedAt: Date(),
                                   duration: duration,
                                   frames: frames,
                                   avgFPS: fpsSum / Double(frames),
                                   hadCourtMap: hadCourtMap)
        record.save()
        return record
    }
}

// MARK: - Formatting helpers (shared by the home screen)

enum Fmt {
    /// "2h ago" / "14m ago" / "just now" - compact enough for a readout column.
    static func ago(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60))m ago"
        case ..<86_400: return "\(Int(s / 3600))h ago"
        default: return "\(Int(s / 86_400))d ago"
        }
    }

    /// "8m 12s" / "45s"
    static func duration(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}
