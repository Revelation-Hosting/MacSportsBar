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

    /// Period 5 is shared: a regular-season shootout vs. a playoff 2nd OT. The feed's detail
    /// disambiguates; without it, count overtimes (no shootout assumed).
    func testHockeyOvertimeVsShootout() {
        let a = adapter(.hockey)
        // Regular-season shootout — feed names it.
        XCTAssertEqual(a.periodLabel(5, detail: "Shootout"), "SO")
        XCTAssertEqual(a.periodLabel(5, detail: "Final/SO"), "SO")
        // Playoff multi-OT — period 5 is the 2nd OT, not a shootout.
        XCTAssertEqual(a.periodLabel(5, detail: "2nd OT"), "2OT")
        XCTAssertEqual(a.periodLabel(6, detail: "3rd OT"), "3OT")
        XCTAssertEqual(a.periodLabel(7), "4OT")
        // No detail: don't assume a shootout — count it as the 2nd OT.
        XCTAssertEqual(a.periodLabel(5), "2OT")
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

    func testLiveDetailHockeyPlayoffDoubleOT() {
        let status = HeadToHeadAdapter.Scoreboard.Status(
            displayClock: "12:03", period: 5,
            type: .init(state: "in", completed: false, shortDetail: "12:03 - 2nd OT"))
        XCTAssertEqual(adapter(.hockey).liveDetail(status), "12:03 2OT")
    }

    func testLiveDetailHockeyShootout() {
        let status = HeadToHeadAdapter.Scoreboard.Status(
            displayClock: "0:00", period: 5,
            type: .init(state: "in", completed: false, shortDetail: "Shootout"))
        XCTAssertEqual(adapter(.hockey).liveDetail(status), "0:00 SO")
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
