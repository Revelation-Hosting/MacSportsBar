import XCTest
@testable import MacSportsBar

/// Tests for the structured per-league team-favorites store on `Settings`.
final class TeamFavoritesTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "MacSportsBarTests.teamFav.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testToggleStoresLowercasedAndPrunesEmpty() {
        let settings = Settings(defaults: freshDefaults())
        XCTAssertFalse(settings.isFavoriteTeam("SEA", in: "mlb"))

        settings.setFavoriteTeam("SEA", in: "mlb", on: true)
        XCTAssertTrue(settings.isFavoriteTeam("sea", in: "mlb"), "match is case-insensitive")
        XCTAssertEqual(settings.teamFavorites["mlb"], ["sea"], "stored lowercased")

        settings.setFavoriteTeam("SEA", in: "mlb", on: false)
        XCTAssertFalse(settings.isFavoriteTeam("SEA", in: "mlb"))
        XCTAssertNil(settings.teamFavorites["mlb"], "an emptied league is pruned")
    }

    func testFavoritesPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = Settings(defaults: defaults)
        first.setFavoriteTeam("NYK", in: "nba", on: true)
        first.setFavoriteTeam("BOS", in: "nba", on: true)

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.teamFavorites["nba"], ["nyk", "bos"])
    }

    func testIsolatedPerLeague() {
        let settings = Settings(defaults: freshDefaults())
        settings.setFavoriteTeam("NY", in: "nba", on: true)   // Knicks
        settings.setFavoriteTeam("NY", in: "mlb", on: true)   // Yankees, same abbrev, different league
        XCTAssertTrue(settings.isFavoriteTeam("ny", in: "nba"))
        XCTAssertTrue(settings.isFavoriteTeam("ny", in: "mlb"))
        settings.setFavoriteTeam("NY", in: "nba", on: false)
        XCTAssertFalse(settings.isFavoriteTeam("ny", in: "nba"))
        XCTAssertTrue(settings.isFavoriteTeam("ny", in: "mlb"), "leagues are independent")
    }
}
