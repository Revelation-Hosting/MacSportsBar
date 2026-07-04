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

    // MARK: - Stale-final filter (idle/off-season leagues keep returning their last game)

    private func dated(_ id: String, _ state: SportEvent.State, date: Date?) -> SportEvent {
        SportEvent(id: id, league: league, state: state, displayString: id,
                   isFavorite: false, sortPriority: 0, date: date)
    }

    func testDropsFinalsOlderThan24h() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let events = [
            dated("old", .final, date: now.addingTimeInterval(-21 * 86_400)),  // 3 weeks → drop
            dated("recent", .final, date: now.addingTimeInterval(-3600)),       // 1h → keep
            dated("live", .live, date: now.addingTimeInterval(-9999)),          // live → keep
            dated("upcoming", .pre(startDate: nil), date: now.addingTimeInterval(7200)), // keep
            dated("nodate", .final, date: nil),                                 // no date → keep
        ]
        let fresh = AppModel.freshDisplayEvents(events, now: now).map(\.id)
        XCTAssertEqual(fresh, ["recent", "live", "upcoming", "nodate"])
        XCTAssertFalse(fresh.contains("old"), "a 3-week-old final must not linger")
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
