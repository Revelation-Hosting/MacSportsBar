import XCTest
@testable import MacSportsBar

/// Tests for the generic `HeadToHeadAdapter` across its three period styles (football
/// quarters, hockey periods, soccer minutes).
final class HeadToHeadAdapterTests: XCTestCase {

    private func adapter(_ style: HeadToHeadAdapter.PeriodStyle,
                         favorites: Set<String> = []) -> HeadToHeadAdapter {
        HeadToHeadAdapter(
            league: LeagueID(sport: "football", league: "nfl", displayName: "NFL"),
            favorites: favorites, style: style
        )
    }

    private func firstEvent(_ json: String) throws -> HeadToHeadAdapter.Scoreboard.Event {
        let board = try JSONDecoder().decode(HeadToHeadAdapter.Scoreboard.self, from: Data(json.utf8))
        return try XCTUnwrap(board.events?.first)
    }

    // MARK: - Period labels

    func testQuartersPeriodLabels() {
        let a = adapter(.quarters)
        XCTAssertEqual(a.periodLabel(nil), "")
        XCTAssertEqual(a.periodLabel(0), "")
        XCTAssertEqual(a.periodLabel(1), "Q1")
        XCTAssertEqual(a.periodLabel(4), "Q4")
        XCTAssertEqual(a.periodLabel(5), "OT")
        XCTAssertEqual(a.periodLabel(6), "2OT")
    }

    func testHockeyPeriodLabels() {
        let a = adapter(.hockey)
        XCTAssertEqual(a.periodLabel(1), "1st")
        XCTAssertEqual(a.periodLabel(2), "2nd")
        XCTAssertEqual(a.periodLabel(3), "3rd")
        XCTAssertEqual(a.periodLabel(4), "OT")
    }

    func testSoccerHasNoPeriodLabel() {
        XCTAssertEqual(adapter(.soccer).periodLabel(2), "")
    }

    // MARK: - Live detail

    func testLiveDetailQuarters() {
        let status = HeadToHeadAdapter.Scoreboard.Status(
            displayClock: "7:30", period: 3,
            type: .init(state: "in", completed: false, shortDetail: "7:30 - 3rd Quarter"))
        XCTAssertEqual(adapter(.quarters).liveDetail(status), "7:30 Q3")
    }

    func testLiveDetailHockey() {
        let status = HeadToHeadAdapter.Scoreboard.Status(
            displayClock: "4:11", period: 2,
            type: .init(state: "in", completed: false, shortDetail: nil))
        XCTAssertEqual(adapter(.hockey).liveDetail(status), "4:11 2nd")
    }

    func testLiveDetailSoccerUsesShortDetail() {
        let status = HeadToHeadAdapter.Scoreboard.Status(
            displayClock: "67'", period: 2,
            type: .init(state: "in", completed: false, shortDetail: "67'"))
        XCTAssertEqual(adapter(.soccer).liveDetail(status), "67'")
    }

    // MARK: - Mapping

    func testMapLiveFootball() throws {
        let json = """
        {"events":[{"id":"nfl1","status":{"displayClock":"7:30","period":3,"type":{"state":"in"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"21","team":{"abbreviation":"SEA"}},
            {"homeAway":"away","score":"14","team":{"abbreviation":"NE"}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter(.quarters).map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "NE 14  SEA 21 · 7:30 Q3")
        XCTAssertEqual(mapped.sortPriority, 800)
    }

    func testMapLiveSoccer() throws {
        let json = """
        {"events":[{"id":"s1","status":{"displayClock":"67'","type":{"state":"in","shortDetail":"67'"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"0","team":{"abbreviation":"BHA"}},
            {"homeAway":"away","score":"3","team":{"abbreviation":"MAN"}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter(.soccer).map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "MAN 3  BHA 0 · 67'")
    }

    func testMapFinal() throws {
        let json = """
        {"events":[{"id":"f","status":{"type":{"state":"post"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"1","team":{"abbreviation":"VGK"}},
            {"homeAway":"away","score":"2","team":{"abbreviation":"CAR"}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter(.hockey).map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "CAR 2  VGK 1 · Final")
    }

    func testMapPrePrefix() throws {
        let json = """
        {"events":[{"id":"p","date":"2026-09-09T00:20Z","status":{"type":{"state":"pre","shortDetail":"9/8 - 8:20 PM EDT"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"0","team":{"abbreviation":"SEA"}},
            {"homeAway":"away","score":"0","team":{"abbreviation":"NE"}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter(.quarters).map(firstEvent(json)))
        XCTAssertTrue(mapped.displayString.hasPrefix("NE vs SEA"), mapped.displayString)
    }
}
