import XCTest
@testable import MacSportsBar

/// The dropdown's layout: favorites at the top level, every other shown game in a flyout per
/// league. The regression it guards: a flat eight-row list where fifteen upcoming NFL games
/// pushed every Top-25 college final out of sight.
final class MenuLayoutTests: XCTestCase {

    private let nfl = LeagueID(sport: "football", league: "nfl", displayName: "NFL")
    private let ncaaf = LeagueID(sport: "football", league: "college-football", displayName: "NCAAF",
                                 hasRankings: true)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, _ league: LeagueID, _ state: SportEvent.State,
                       favorite: Bool = false, hoursFromNow: Double = 0) -> SportEvent {
        SportEvent(id: id, league: league, state: state, displayString: id,
                   isFavorite: favorite, sortPriority: 0,
                   date: now.addingTimeInterval(hoursFromNow * 3600))
    }

    func testABusyLeagueNoLongerHidesAnothersGames() {
        // Saturday night: a full NFL week still to play, and the ranked college finals.
        let upcomingNFL = (1...15).map { event("nfl-\($0)", nfl, .pre(startDate: nil), hoursFromNow: Double($0)) }
        let ranked = [event("cfb-a", ncaaf, .final, hoursFromNow: -3), event("cfb-b", ncaaf, .final, hoursFromNow: -1)]
        let layout = MenuLayout(digest: [], events: upcomingNFL + ranked,
                                leagueOrder: ["nfl", "college-football"])

        XCTAssertEqual(layout.leagues.map(\.id), ["nfl", "college-football"])
        XCTAssertEqual(layout.leagues[0].upcoming.count, 15, "nothing is capped away")
        XCTAssertEqual(layout.leagues[1].finals.map(\.id), ["cfb-b", "cfb-a"], "most recent final first")
    }

    func testFavoritesStayTopLevelIncludingOnesLaterInTheWeek() {
        let tonight = event("tenn-tonight", ncaaf, .pre(startDate: nil), favorite: true, hoursFromNow: 5)
        let saturday = event("wash-sat", ncaaf, .pre(startDate: nil), favorite: true, hoursFromNow: 90)
        let other = event("ranked", ncaaf, .pre(startDate: nil), hoursFromNow: 6)
        // The digest only covers ±24h; Saturday's favorite comes from the full event list.
        let layout = MenuLayout(digest: [tonight], events: [tonight, saturday, other],
                                leagueOrder: ["college-football"])

        XCTAssertEqual(layout.favorites.map(\.id), ["tenn-tonight", "wash-sat"])
        XCTAssertEqual(layout.leagues.first?.upcoming.map(\.id), ["ranked"],
                       "favorites aren't repeated in the flyout")
    }

    func testFlyoutGroupsLiveThenUpcomingSoonestFirst() throws {
        let layout = MenuLayout(digest: [], events: [
            event("later", ncaaf, .pre(startDate: nil), hoursFromNow: 4),
            event("live", ncaaf, .live),
            event("soon", ncaaf, .pre(startDate: nil), hoursFromNow: 1),
        ], leagueOrder: ["college-football"])

        let group = try XCTUnwrap(layout.leagues.first)
        XCTAssertEqual(group.live.map(\.id), ["live"])
        XCTAssertEqual(group.upcoming.map(\.id), ["soon", "later"])
        XCTAssertEqual(group.title, "NCAAF · 1 live")
    }

    func testTitleIsJustTheLeagueWhenNothingIsLive() {
        let layout = MenuLayout(digest: [], events: [event("x", nfl, .final)], leagueOrder: ["nfl"])
        XCTAssertEqual(layout.leagues.first?.title, "NFL")
    }

    func testLeaguesWithNothingLeftGetNoFlyout() {
        // Everything in NCAAF is a favorite (already at the top), so no empty NCAAF flyout.
        let layout = MenuLayout(digest: [], events: [
            event("fav", ncaaf, .live, favorite: true), event("nfl", nfl, .live),
        ], leagueOrder: ["nfl", "college-football"])
        XCTAssertEqual(layout.leagues.map(\.id), ["nfl"])
    }

    func testFavoritesPastTheRowLimitFallThroughToTheirFlyout() {
        let favorites = (0..<(MenuLayout.favoritesLimit + 2)).map {
            event("fav-\($0)", nfl, .pre(startDate: nil), favorite: true, hoursFromNow: Double($0))
        }
        let layout = MenuLayout(digest: [], events: favorites, leagueOrder: ["nfl"])
        XCTAssertEqual(layout.favorites.count, MenuLayout.favoritesLimit)
        XCTAssertEqual(layout.leagues.first?.upcoming.count, 2, "overflow is still reachable")
    }
}
