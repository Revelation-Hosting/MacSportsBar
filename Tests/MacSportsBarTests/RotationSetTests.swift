import XCTest
@testable import MacSportsBar

/// Tests for the menu-bar rotation set: live always, finished/upcoming gated by the switches.
final class RotationSetTests: XCTestCase {

    private let league = LeagueID(sport: "baseball", league: "mlb", displayName: "MLB")
    private func ev(_ id: String, _ state: SportEvent.State) -> SportEvent {
        SportEvent(id: id, league: league, state: state, displayString: id,
                   isFavorite: true, sortPriority: 0)
    }

    func testLiveAlwaysIncludedRegardlessOfSwitches() {
        let live = [ev("l1", .live), ev("l2", .live)]
        let result = AppModel.rotationSet(live: live, windowNonLive: [], upcomingFavorites: [],
                                          includeFinished: false, includeUpcoming: false, fallback: live)
        XCTAssertEqual(result.map(\.id), ["l1", "l2"])
    }

    func testFinishedAndUpcomingGatedBySwitches() {
        let live = [ev("live", .live)]
        let window = [ev("final", .final), ev("upcoming", .pre(startDate: nil))]
        func ids(_ f: Bool, _ u: Bool) -> [String] {
            AppModel.rotationSet(live: live, windowNonLive: window, upcomingFavorites: [],
                                 includeFinished: f, includeUpcoming: u, fallback: live).map(\.id)
        }
        XCTAssertEqual(ids(true, false), ["live", "final"])
        XCTAssertEqual(ids(false, true), ["live", "upcoming"])
        XCTAssertEqual(ids(true, true), ["live", "final", "upcoming"])
        XCTAssertEqual(ids(false, false), ["live"])
    }

    func testFallsBackToTopWhenNothingQualifies() {
        let fallback = [ev("top", .final), ev("next", .pre(startDate: nil))]
        let result = AppModel.rotationSet(live: [], windowNonLive: [], upcomingFavorites: [],
                                          includeFinished: false, includeUpcoming: false, fallback: fallback)
        XCTAssertEqual(result.map(\.id), ["top"])
    }

    /// A quiet weekday: nothing live, no favorite within 24h, but the week's board has several
    /// favorites coming up. They rotate soonest-first instead of the bar freezing on the top one.
    func testUpcomingFavoritesBeyondTheWindowRotateSoonestFirst() {
        let now = Date()
        func pre(_ id: String, inDays days: Double) -> SportEvent {
            var event = ev(id, .pre(startDate: now.addingTimeInterval(days * 86_400)))
            event.date = now.addingTimeInterval(days * 86_400)
            return event
        }
        let sunday = pre("sun", inDays: 4), saturday = pre("sat", inDays: 3)
        let golf = ev("golf", .pre(startDate: now.addingTimeInterval(86_400)))  // no `date`
        let result = AppModel.rotationSet(
            live: [], windowNonLive: [], upcomingFavorites: [sunday, saturday, golf],
            includeFinished: true, includeUpcoming: true, fallback: [sunday])
        XCTAssertEqual(result.map(\.id), ["golf", "sat", "sun"])
    }

    func testUpcomingFavoritesJoinAfterLiveAndWindowWithoutDuplicates() {
        let live = [ev("live", .live)]
        let window = [ev("final", .final), ev("tomorrow", .pre(startDate: nil))]
        let upcoming = [ev("tomorrow", .pre(startDate: nil)), ev("sunday", .pre(startDate: nil))]
        let result = AppModel.rotationSet(
            live: live, windowNonLive: window, upcomingFavorites: upcoming,
            includeFinished: true, includeUpcoming: true, fallback: live)
        XCTAssertEqual(result.map(\.id), ["live", "final", "tomorrow", "sunday"])
    }

    func testUpcomingSwitchOffKeepsDistantFavoritesOut() {
        let upcoming = [ev("sat", .pre(startDate: nil)), ev("sun", .pre(startDate: nil))]
        let result = AppModel.rotationSet(
            live: [], windowNonLive: [], upcomingFavorites: upcoming,
            includeFinished: true, includeUpcoming: false, fallback: upcoming)
        XCTAssertEqual(result.map(\.id), ["sat"])
    }
}
