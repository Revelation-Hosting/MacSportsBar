import XCTest
@testable import MacSportsBar

/// Tests for `RacingAdapter`'s race-name shortening, driver surnames, and degraded formatting.
final class RacingAdapterTests: XCTestCase {

    private let nascar = LeagueID(sport: "racing", league: "nascar-premier", displayName: "NASCAR")
    private func adapter(_ favorites: Set<String> = []) -> RacingAdapter {
        RacingAdapter(league: nascar, favorites: favorites)
    }

    private func firstEvent(_ json: String) throws -> RacingAdapter.Scoreboard.Event {
        let board = try JSONDecoder().decode(RacingAdapter.Scoreboard.self, from: Data(json.utf8))
        return try XCTUnwrap(board.events?.first)
    }

    // MARK: - Helpers

    func testShortRace() {
        let a = adapter()
        XCTAssertEqual(a.shortRace("NASCAR Cup Series at Michigan"), "Michigan")
        XCTAssertEqual(a.shortRace("Coca-Cola 600"), "Coca-Cola 600")
        XCTAssertEqual(a.shortRace("NASCAR Cup Series Daytona 500"), "Daytona 500")
    }

    func testLastNameSkipsSuffix() {
        XCTAssertEqual(RacingAdapter.lastName("Ricky Stenhouse Jr."), "Stenhouse")
        XCTAssertEqual(RacingAdapter.lastName("Kyle Larson"), "Larson")
    }

    // MARK: - Mapping

    func testPreShowsRaceCupAndTime() throws {
        let json = """
        {"events":[{"id":"r1","name":"NASCAR Cup Series at Michigan",
          "status":{"type":{"state":"pre","shortDetail":"6/7 - 3:00 PM EDT"}},
          "competitions":[{"competitors":[]}]}]}
        """
        let mapped = adapter().map(try firstEvent(json))
        XCTAssertTrue(mapped.displayString.hasPrefix("Michigan · Cup"), mapped.displayString)
        guard case .pre = mapped.state else { return XCTFail("expected .pre") }
    }

    func testLiveShowsLeader() throws {
        let json = """
        {"events":[{"id":"r2","name":"NASCAR Cup Series at Michigan",
          "status":{"type":{"state":"in"}},
          "competitions":[{"competitors":[{"order":1,"athlete":{"displayName":"Kyle Larson"}}]}]}]}
        """
        let mapped = adapter().map(try firstEvent(json))
        XCTAssertEqual(mapped.displayString, "Michigan · Larson leading")
        guard case .live = mapped.state else { return XCTFail("expected .live") }
    }

    func testFinalShowsWinner() throws {
        let json = """
        {"events":[{"id":"r3","name":"Coca-Cola 600","status":{"type":{"state":"post"}},
          "competitions":[{"competitors":[{"order":1,"athlete":{"displayName":"Ross Chastain"}}]}]}]}
        """
        let mapped = adapter().map(try firstEvent(json))
        XCTAssertEqual(mapped.displayString, "Coca-Cola 600 · Chastain won")
        guard case .final = mapped.state else { return XCTFail("expected .final") }
    }

    func testEveryStateCarriesTheRaceDate() throws {
        // Regression: only upcoming races were dated, so a finished race never aged out of the
        // menu — ESPN served Sunday's Kansas result until midweek.
        let start = Date(timeIntervalSince1970: 1_790_535_600)  // 2026-09-27T19:00Z
        for state in ["pre", "in", "post"] {
            let json = """
            {"events":[{"id":"r5","name":"NASCAR Cup Series at Kansas","date":"2026-09-27T19:00Z",
              "status":{"type":{"state":"\(state)"}},
              "competitions":[{"competitors":[{"order":1,"athlete":{"displayName":"Kyle Larson"}}]}]}]}
            """
            XCTAssertEqual(adapter().map(try firstEvent(json)).date, start, state)
        }
    }

    func testFinishedRaceAgesOutAfterADay() throws {
        let json = """
        {"events":[{"id":"r6","name":"NASCAR Cup Series at Kansas","date":"2026-09-27T19:00Z",
          "status":{"type":{"state":"post"}},
          "competitions":[{"competitors":[{"order":1,"athlete":{"displayName":"Kyle Larson"}}]}]}]}
        """
        let final = adapter().map(try firstEvent(json))
        let start = try XCTUnwrap(final.date)
        XCTAssertEqual(AppModel.freshDisplayEvents([final], now: start.addingTimeInterval(20 * 3600)).count, 1,
                       "the evening after, the result still shows")
        XCTAssertTrue(AppModel.freshDisplayEvents([final], now: start.addingTimeInterval(46 * 3600)).isEmpty,
                      "by Tuesday it's gone")
    }

    func testFavoriteDriverLeading() throws {
        let json = """
        {"events":[{"id":"r4","name":"NASCAR Cup Series at Michigan","status":{"type":{"state":"in"}},
          "competitions":[{"competitors":[{"order":1,"athlete":{"displayName":"Kyle Larson"}}]}]}]}
        """
        let mapped = adapter(["larson"]).map(try firstEvent(json))
        XCTAssertTrue(mapped.isFavorite)
        XCTAssertEqual(mapped.sortPriority, 1000)
    }
}
