import XCTest
@testable import MacSportsBar

/// Tests for following a whole series (golf/NASCAR have no team to pick), via
/// `AppModel.applyFollowedLeagues` and the `Settings` follow helpers. Following a series
/// promotes its events to favorites so they survive the favorites-only filter.
final class FollowedLeaguesTests: XCTestCase {

    private let nascar = LeagueID(sport: "racing", league: "nascar-premier", displayName: "NASCAR")
    private let nba = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")

    private func event(_ id: String, _ league: LeagueID, favorite: Bool) -> SportEvent {
        SportEvent(id: id, league: league, state: .live, displayString: id,
                   isFavorite: favorite, sortPriority: 0)
    }

    func testPromotesFollowedLeagueEventsToFavorite() {
        let events = [event("race", nascar, favorite: false), event("game", nba, favorite: false)]
        let result = AppModel.applyFollowedLeagues(events, followed: ["nascar-premier"])
        XCTAssertTrue(result.first { $0.id == "race" }!.isFavorite, "followed series is promoted")
        XCTAssertFalse(result.first { $0.id == "game" }!.isFavorite, "other leagues untouched")
    }

    func testNoFollowsIsIdentity() {
        let events = [event("race", nascar, favorite: false)]
        let result = AppModel.applyFollowedLeagues(events, followed: [])
        XCTAssertFalse(result[0].isFavorite)
    }

    func testKeepsExistingFavoriteFlag() {
        // A driver-matched race already favorite stays favorite even if not followed.
        let events = [event("race", nascar, favorite: true)]
        let result = AppModel.applyFollowedLeagues(events, followed: [])
        XCTAssertTrue(result[0].isFavorite)
    }

    func testFollowedRaceSurvivesFavoritesOnlyFilter() {
        // The end-to-end point: with favorites-only on, a followed race must not be filtered out.
        let events = AppModel.applyFollowedLeagues(
            [event("race", nascar, favorite: false), event("game", nba, favorite: false)],
            followed: ["nascar-premier"])
        let shown = AppModel.displaySet(from: events, favoritesOnly: true, hasFavorites: true)
        XCTAssertEqual(shown.map(\.id), ["race"])
    }

    func testSettingsFollowHelpersAndHasAnyFavorites() {
        let suite = "MacSportsBarTests.follow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = Settings(defaults: defaults)

        XCTAssertFalse(settings.hasAnyFavorites)
        XCTAssertFalse(settings.isFollowingLeague("nascar-premier"))
        settings.setFollowingLeague("nascar-premier", on: true)
        XCTAssertTrue(settings.isFollowingLeague("nascar-premier"))
        XCTAssertTrue(settings.hasAnyFavorites, "a followed series counts as a favorite")
        settings.setFollowingLeague("nascar-premier", on: false)
        XCTAssertFalse(settings.isFollowingLeague("nascar-premier"))
        XCTAssertFalse(settings.hasAnyFavorites)
    }
}
