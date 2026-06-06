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
        let result = AppModel.rotationSet(live: live, windowNonLive: [],
                                          includeFinished: false, includeUpcoming: false, fallback: live)
        XCTAssertEqual(result.map(\.id), ["l1", "l2"])
    }

    func testFinishedAndUpcomingGatedBySwitches() {
        let live = [ev("live", .live)]
        let window = [ev("final", .final), ev("upcoming", .pre(startDate: nil))]
        func ids(_ f: Bool, _ u: Bool) -> [String] {
            AppModel.rotationSet(live: live, windowNonLive: window,
                                 includeFinished: f, includeUpcoming: u, fallback: live).map(\.id)
        }
        XCTAssertEqual(ids(true, false), ["live", "final"])
        XCTAssertEqual(ids(false, true), ["live", "upcoming"])
        XCTAssertEqual(ids(true, true), ["live", "final", "upcoming"])
        XCTAssertEqual(ids(false, false), ["live"])
    }

    func testFallsBackToTopWhenNothingQualifies() {
        let fallback = [ev("top", .final), ev("next", .pre(startDate: nil))]
        let result = AppModel.rotationSet(live: [], windowNonLive: [],
                                          includeFinished: false, includeUpcoming: false, fallback: fallback)
        XCTAssertEqual(result.map(\.id), ["top"])
    }
}
