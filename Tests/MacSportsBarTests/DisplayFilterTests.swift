import XCTest
@testable import MacSportsBar

/// Regression tests for the favorites-only display filter. The original guard only checked the
/// free-form tokens, so picking teams in the structured picker (which stores them in
/// `teamFavorites`) left the filter inert — these lock the corrected behavior.
final class DisplayFilterTests: XCTestCase {

    private let league = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
    private func event(_ id: String, favorite: Bool) -> SportEvent {
        SportEvent(id: id, league: league, state: .live, displayString: id,
                   isFavorite: favorite, sortPriority: 0)
    }

    func testFiltersToFavoritesWhenFavoritesExist() {
        let events = [event("a", favorite: true), event("b", favorite: false), event("c", favorite: true)]
        let shown = AppModel.displaySet(from: events, favoritesOnly: true, hasFavorites: true)
        XCTAssertEqual(shown.map(\.id), ["a", "c"])
    }

    func testShowsEverythingWhenToggleOnButNoFavorites() {
        // Never filter down to nothing when "favorites only" is on but nothing is favorited.
        let events = [event("a", favorite: false), event("b", favorite: false)]
        let shown = AppModel.displaySet(from: events, favoritesOnly: true, hasFavorites: false)
        XCTAssertEqual(shown.map(\.id), ["a", "b"])
    }

    func testShowsEverythingWhenToggleOff() {
        let events = [event("a", favorite: true), event("b", favorite: false)]
        let shown = AppModel.displaySet(from: events, favoritesOnly: false, hasFavorites: true)
        XCTAssertEqual(shown.map(\.id), ["a", "b"])
    }

    func testHasAnyFavoritesCountsStructuredPicks() {
        let suite = "MacSportsBarTests.hasFav.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = Settings(defaults: defaults)

        XCTAssertFalse(settings.hasAnyFavorites)
        settings.setFavoriteTeam("SEA", in: "mlb", on: true)
        XCTAssertTrue(settings.hasAnyFavorites, "a structured pick counts")
        settings.setFavoriteTeam("SEA", in: "mlb", on: false)
        XCTAssertFalse(settings.hasAnyFavorites)
        settings.favorites = "Scheffler"
        XCTAssertTrue(settings.hasAnyFavorites, "free-form tokens count too")
    }
}
