import SwiftUI

/// Owns the polling loop and the ranked list of events. For M1 this is hardcoded to NBA
/// with a fixed 30s cadence and no favorites; later milestones add the settings window,
/// favorites, more sports, and adaptive polling.
@MainActor
final class AppModel: ObservableObject {
    /// The single string rendered in the menu bar.
    @Published var menuBarText: String = "Loading…"
    /// Ranked events, surfaced in the dropdown menu.
    @Published var events: [SportEvent] = []

    private let client = ESPNClient()
    private let adapters: [SportAdapter]
    private var pollTask: Task<Void, Never>?

    /// Fixed poll cadence for the M1 slice. (M3 makes this adaptive.)
    private let pollInterval: Duration = .seconds(30)

    init() {
        // M1 POC: NBA only. NCAA Men's uses this same adapter with the
        // "mens-college-basketball" slug, but it's off-season in June.
        let nba = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
        adapters = [BasketballAdapter(league: nba, favorites: [])]
        start()
    }

    /// (Re)start the polling loop.
    func start() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Fetch every adapter once, rank the results, and update the published state.
    func refresh() async {
        var collected: [SportEvent] = []
        for adapter in adapters {
            do {
                collected += try await adapter.fetch(using: client)
            } catch {
                // Degrade gracefully: one sport failing must never take down the others.
                continue
            }
        }
        events = collected.sorted { $0.sortPriority > $1.sortPriority }
        menuBarText = events.first?.displayString ?? "No games"
    }
}
