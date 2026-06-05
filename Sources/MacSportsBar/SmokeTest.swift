import Foundation

/// One-shot, headless verification of the live data pipeline. Run with:
///
///     swift run MacSportsBar --smoke-test
///
/// Fetches the configured league(s) once, formats each event, and prints the menu-bar
/// strings. Proves fetch → decode → format end to end without launching the GUI.
enum SmokeTest {
    static func run() async {
        let client = ESPNClient()
        let nba = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
        let adapter = BasketballAdapter(league: nba, favorites: [])

        do {
            let events = try await adapter.fetch(using: client)
                .sorted { $0.sortPriority > $1.sortPriority }
            print("Fetched \(events.count) \(nba.displayName) event(s):")
            if events.isEmpty {
                print("  (no games today)")
            }
            for event in events {
                print("  • \(event.displayString)")
            }
        } catch {
            print("Smoke test failed: \(error)")
        }
    }
}
