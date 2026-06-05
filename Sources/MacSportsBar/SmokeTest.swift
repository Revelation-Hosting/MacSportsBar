import Foundation

/// One-shot, headless verification of the live data pipeline. Run with:
///
///     swift run MacSportsBar --smoke-test
///
/// Fetches every league in the catalog once, formats each event, and prints the menu-bar
/// strings. Proves fetch → decode → format end to end without launching the GUI.
enum SmokeTest {
    static func run() async {
        let client = ESPNClient()
        for league in LeagueCatalog.all {
            let adapter = league.makeAdapter([])
            do {
                let events = try await adapter.fetch(using: client)
                    .sorted { $0.sortPriority > $1.sortPriority }
                print("\(league.league.displayName): \(events.count) event(s)")
                if events.isEmpty { print("  (no games today)") }
                for event in events.prefix(12) {
                    print("  • \(event.displayString)")
                }
            } catch {
                print("\(league.league.displayName): fetch failed — \(error)")
            }
        }
    }
}
