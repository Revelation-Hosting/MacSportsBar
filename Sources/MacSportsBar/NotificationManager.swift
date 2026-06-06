import Foundation
import UserNotifications

/// Posts macOS notifications for favorite teams when a game crosses a *meaningful boundary* —
/// a new period/inning/half, or the game going final. Deliberately not per-score-change, which
/// would be spammy for something like basketball.
///
/// Notifications require a bundled app (a bundle identifier + the user's permission), so this
/// is a no-op when run via `swift run`; install via `scripts/build-app.sh`.
@MainActor
final class NotificationManager {
    /// The comparable game state diffed between polls.
    struct Snapshot: Equatable {
        var period: Int?
        var isFinal: Bool
    }

    /// What changed since the previous poll.
    enum Boundary: Equatable {
        case none
        case periodAdvanced
        case final
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
        if let prev = previous.period, let cur = current.period, cur > prev { return .periodAdvanced }
        return .none
    }

    func requestAuthorizationIfNeeded() {
        guard isAvailable, !requestedAuth else { return }
        requestedAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Diff the favorite events against the previous poll and post boundary notifications.
    func process(events: [SportEvent], enabled: Bool) {
        guard isAvailable, enabled else {
            // Drop snapshots so re-enabling later doesn't replay a stale transition.
            lastSnapshots.removeAll()
            return
        }
        for event in events where event.isFavorite {
            let current = Snapshot(period: event.period, isFinal: event.isFinal)
            switch Self.boundary(from: lastSnapshots[event.id], to: current) {
            case .final:
                post(title: "Final · \(event.league.displayName)", body: event.displayString)
            case .periodAdvanced:
                post(title: event.league.displayName, body: event.displayString)
            case .none:
                break
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
