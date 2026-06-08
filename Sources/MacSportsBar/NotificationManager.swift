import Foundation
import UserNotifications

/// Posts macOS notifications for favorite teams when a game crosses a *meaningful boundary* —
/// it starts, a new period/inning/half begins, or it goes final. Deliberately not
/// per-score-change, which would be spammy for something like basketball.
///
/// Notifications require a bundled app (a bundle identifier + the user's permission), so this
/// is a no-op when run via `swift run`; install via `scripts/build-app.sh`.
@MainActor
final class NotificationManager {
    /// The comparable game state diffed between polls.
    struct Snapshot: Equatable {
        var period: Int?
        var isFinal: Bool
        /// Whether the game is in progress, so a pre→live transition can fire a "started" alert.
        var isLive: Bool = false
    }

    /// What changed since the previous poll.
    enum Boundary: Equatable {
        case none
        case started
        case periodAdvanced
        case final
    }

    /// Which boundary kinds the user wants notified — each independently toggleable.
    struct Preferences: Equatable {
        var start: Bool
        var period: Bool
        var final: Bool
    }

    /// Whether a boundary should post, given the user's per-kind preferences. Pure — a tested seam.
    nonisolated static func shouldNotify(_ boundary: Boundary, prefs: Preferences) -> Bool {
        switch boundary {
        case .started:        return prefs.start
        case .periodAdvanced: return prefs.period
        case .final:          return prefs.final
        case .none:           return false
        }
    }

    private var lastSnapshots: [String: Snapshot] = [:]
    private var requestedAuth = false

    /// Notifications only work from a bundled `.app` — `UNUserNotificationCenter` needs a
    /// bundle identifier, which a bare `swift run` binary lacks.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Pure boundary classifier — the seam the tests exercise. The first sighting of a game
    /// (no previous snapshot) never notifies, so launching mid-game stays quiet.
    nonisolated static func boundary(from previous: Snapshot?, to current: Snapshot) -> Boundary {
        guard let previous else { return .none }
        if !previous.isFinal && current.isFinal { return .final }
        if !previous.isLive && current.isLive { return .started }    // pre → live (tip-off / first pitch)
        if let prev = previous.period, let cur = current.period, cur > prev { return .periodAdvanced }
        return .none
    }

    func requestAuthorizationIfNeeded() {
        guard isAvailable, !requestedAuth else { return }
        requestedAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Diff the favorite events against the previous poll and post boundary notifications the
    /// user has opted into. `enabled` is the master switch; `prefs` chooses which kinds fire.
    func process(events: [SportEvent], enabled: Bool, prefs: Preferences) {
        guard isAvailable, enabled else {
            // Drop snapshots so re-enabling later doesn't replay a stale transition.
            lastSnapshots.removeAll()
            return
        }
        for event in events where event.isFavorite {
            let current = Snapshot(period: event.period, isFinal: event.isFinal, isLive: event.isLive)
            let boundary = Self.boundary(from: lastSnapshots[event.id], to: current)
            // Always advance the snapshot (so a muted kind doesn't desync the diff); only post
            // the kinds the user enabled.
            if Self.shouldNotify(boundary, prefs: prefs) {
                switch boundary {
                case .final:          post(title: "Final · \(event.league.displayName)", body: event.displayString)
                case .started:        post(title: "Starting · \(event.league.displayName)", body: event.displayString)
                case .periodAdvanced: post(title: event.league.displayName, body: event.displayString)
                case .none:           break
                }
            }
            lastSnapshots[event.id] = current
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
