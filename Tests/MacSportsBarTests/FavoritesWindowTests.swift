import XCTest
@testable import MacSportsBar

/// Tests for the ±24h favorites window: recent finals + live + upcoming, deduped and sorted.
final class FavoritesWindowTests: XCTestCase {

    private let league = LeagueID(sport: "baseball", league: "mlb", displayName: "MLB")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // fixed reference instant

    private func event(_ id: String, state: SportEvent.State, hoursFromNow: Double?) -> SportEvent {
        SportEvent(id: id, league: league, state: state, displayString: id, isFavorite: true,
                   sortPriority: 0, date: hoursFromNow.map { now.addingTimeInterval($0 * 3600) })
    }

    func testKeepsRecentAndUpcomingWithin24hAndDropsOutside() {
        let events = [
            event("recent", state: .final, hoursFromNow: -6),     // 6h ago — keep
            event("stale", state: .final, hoursFromNow: -30),     // 30h ago — drop
            event("soon", state: .pre(startDate: nil), hoursFromNow: 5),   // in 5h — keep
            event("far", state: .pre(startDate: nil), hoursFromNow: 40),   // in 40h — drop
        ]
        let window = AppModel.windowedFavorites(from: events, now: now)
        XCTAssertEqual(window.map(\.id), ["recent", "soon"])  // sorted by date ascending
    }

    func testLiveIsAlwaysKeptEvenWithoutDate() {
        let events = [event("live", state: .live, hoursFromNow: nil)]
        XCTAssertEqual(AppModel.windowedFavorites(from: events, now: now).map(\.id), ["live"])
    }

    func testDedupesById() {
        let events = [
            event("dup", state: .final, hoursFromNow: -2),
            event("dup", state: .final, hoursFromNow: -2),
        ]
        XCTAssertEqual(AppModel.windowedFavorites(from: events, now: now).count, 1)
    }

    func testSortsChronologically() {
        let events = [
            event("upcoming", state: .pre(startDate: nil), hoursFromNow: 8),
            event("past", state: .final, hoursFromNow: -8),
            event("live", state: .live, hoursFromNow: 0),
        ]
        XCTAssertEqual(AppModel.windowedFavorites(from: events, now: now).map(\.id),
                       ["past", "live", "upcoming"])
    }
}
