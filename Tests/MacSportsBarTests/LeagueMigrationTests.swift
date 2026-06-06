import XCTest
@testable import MacSportsBar

/// Tests for `Settings`' league auto-enable migration: newly-added leagues turn on for
/// returning users, but leagues they've explicitly opted out of stay off.
final class LeagueMigrationTests: XCTestCase {

    private let allIDs = Set(LeagueCatalog.all.map(\.id))

    private func freshDefaults() -> UserDefaults {
        let suite = "MacSportsBarTests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testFirstRunEnablesAllLeagues() {
        let settings = Settings(defaults: freshDefaults())
        XCTAssertEqual(settings.enabledLeagues, allIDs)
    }

    func testNewLeaguesAutoEnabledButOptOutsRespected() {
        let defaults = freshDefaults()
        defaults.set(["nba"], forKey: "enabledLeagues")      // only NBA switched on
        defaults.set(["nba", "mlb"], forKey: "seenLeagues")  // had seen NBA + MLB → MLB opted out
        let settings = Settings(defaults: defaults)

        XCTAssertTrue(settings.enabledLeagues.contains("nba"))
        XCTAssertFalse(settings.enabledLeagues.contains("mlb"),
                       "a seen, opted-out league must stay off")
        XCTAssertTrue(settings.enabledLeagues.contains("pga"),
                      "a newly-added league should auto-enable")
        XCTAssertEqual(settings.enabledLeagues, allIDs.subtracting(["mlb"]))
    }

    func testEverythingSeenKeepsExactSelection() {
        let defaults = freshDefaults()
        defaults.set(["nba"], forKey: "enabledLeagues")
        defaults.set(Array(allIDs), forKey: "seenLeagues")   // nothing is "new"
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.enabledLeagues, ["nba"])
    }

    func testSeenLeaguesPersistedAfterInit() {
        let defaults = freshDefaults()
        _ = Settings(defaults: defaults)
        let seen = Set(defaults.array(forKey: "seenLeagues") as? [String] ?? [])
        XCTAssertEqual(seen, allIDs)
    }
}
