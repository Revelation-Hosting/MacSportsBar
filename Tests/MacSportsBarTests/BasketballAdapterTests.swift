import XCTest
@testable import MacSportsBar

/// Tests for the pure decode → map → format path in `BasketballAdapter`. No networking:
/// fixtures are decoded from inline JSON (hand-crafted live/final/pre states) or from the
/// bundled real ESPN payload, then run through `map` and asserted.
final class BasketballAdapterTests: XCTestCase {

    // MARK: - League fixtures

    private let nbaLeague = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
    private let ncaaLeague = LeagueID(
        sport: "basketball", league: "mens-college-basketball", displayName: "NCAA Men's"
    )

    private func decode(_ json: String) throws -> BasketballAdapter.Scoreboard {
        try JSONDecoder().decode(BasketballAdapter.Scoreboard.self, from: Data(json.utf8))
    }

    private func firstEvent(_ json: String) throws -> BasketballAdapter.Scoreboard.Event {
        try XCTUnwrap(decode(json).events?.first)
    }

    /// An NBA Knicks @ Spurs game in progress, 4:32 left in Q4. Reused across the
    /// live-formatting, favorite-matching, and sort-priority cases.
    private let liveNBAJSON = """
    {"events":[{"id":"401live","date":"2026-06-06T00:30Z",
      "status":{"displayClock":"4:32","period":4,
                "type":{"state":"in","completed":false,"shortDetail":"4:32 - 4th Quarter"}},
      "competitions":[{"competitors":[
        {"homeAway":"home","score":"98","team":{"abbreviation":"SA","displayName":"San Antonio Spurs","shortDisplayName":"Spurs","location":"San Antonio"}},
        {"homeAway":"away","score":"102","team":{"abbreviation":"NY","displayName":"New York Knicks","shortDisplayName":"Knicks","location":"New York"}}
      ]}]}]}
    """

    // MARK: - Live / final / pre formatting

    func testLiveNBAEventFormatting() throws {
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(liveNBAJSON)))

        XCTAssertEqual(mapped.displayString, "NY 102  SA 98 · 4:32 Q4")
        guard case .live = mapped.state else { return XCTFail("expected .live state") }
        XCTAssertFalse(mapped.isFavorite)
        XCTAssertEqual(mapped.sortPriority, 800)
    }

    func testFinalNBAEventFormatting() throws {
        let json = """
        {"events":[{"id":"401final","date":"2026-06-05T23:00Z",
          "status":{"period":4,"type":{"state":"post","completed":true,"shortDetail":"Final"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"110","team":{"abbreviation":"BOS","displayName":"Boston Celtics","shortDisplayName":"Celtics","location":"Boston"}},
            {"homeAway":"away","score":"104","team":{"abbreviation":"LAL","displayName":"Los Angeles Lakers","shortDisplayName":"Lakers","location":"Los Angeles"}}
          ]}]}]}
        """
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))

        XCTAssertEqual(mapped.displayString, "LAL 104  BOS 110 · Final")
        guard case .final = mapped.state else { return XCTFail("expected .final state") }
        XCTAssertEqual(mapped.sortPriority, 100)
    }

    func testLiveOvertimeUsesOTLabel() throws {
        let json = """
        {"events":[{"id":"ot","status":{"displayClock":"1:10","period":5,"type":{"state":"in"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"120","team":{"abbreviation":"SA"}},
            {"homeAway":"away","score":"118","team":{"abbreviation":"NY"}}
          ]}]}]}
        """
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "NY 118  SA 120 · 1:10 OT")
    }

    // MARK: - Period labels (NBA quarters vs NCAA halves, incl. OT)

    func testNBAPeriodLabels() {
        let a = BasketballAdapter(league: nbaLeague, favorites: [])
        XCTAssertEqual(a.periodLabel(nil), "")
        XCTAssertEqual(a.periodLabel(0), "")
        XCTAssertEqual(a.periodLabel(1), "Q1")
        XCTAssertEqual(a.periodLabel(4), "Q4")
        XCTAssertEqual(a.periodLabel(5), "OT")
        XCTAssertEqual(a.periodLabel(6), "2OT")
        XCTAssertEqual(a.periodLabel(7), "3OT")
    }

    func testNCAAPeriodLabels() {
        let a = BasketballAdapter(league: ncaaLeague, favorites: [])
        XCTAssertEqual(a.periodLabel(nil), "")
        XCTAssertEqual(a.periodLabel(0), "")
        XCTAssertEqual(a.periodLabel(1), "1H")
        XCTAssertEqual(a.periodLabel(2), "2H")
        XCTAssertEqual(a.periodLabel(3), "OT")
        XCTAssertEqual(a.periodLabel(4), "2OT")
        XCTAssertEqual(a.periodLabel(5), "3OT")
    }

    // MARK: - Favorite matching (case-insensitive, multi-field, substring)

    func testFavoriteMatching() throws {
        let event = try firstEvent(liveNBAJSON)
        func isFavorite(_ tokens: Set<String>) throws -> Bool {
            let adapter = BasketballAdapter(league: nbaLeague, favorites: tokens)
            return try XCTUnwrap(adapter.map(event)).isFavorite
        }

        XCTAssertTrue(try isFavorite(["ny"]),        "abbreviation match")
        XCTAssertTrue(try isFavorite(["knicks"]),    "shortDisplayName match")
        XCTAssertTrue(try isFavorite(["new york"]),  "location exact match")
        XCTAssertTrue(try isFavorite(["new"]),       "substring (contains) match")
        XCTAssertTrue(try isFavorite(["spurs"]),     "matches the home team too")
        XCTAssertFalse(try isFavorite(["lakers"]),   "unrelated team is not a favorite")
        XCTAssertFalse(try isFavorite([]),           "no favorites configured")
    }

    func testLiveFavoriteGetsTopSortPriority() throws {
        let adapter = BasketballAdapter(league: nbaLeague, favorites: ["knicks"])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(liveNBAJSON)))
        XCTAssertTrue(mapped.isFavorite)
        XCTAssertEqual(mapped.sortPriority, 1000)
    }

    // MARK: - ISO date parsing (ESPN's no-seconds format, plus the with-seconds variant)

    func testPreGameParsesNoSecondsISODate() throws {
        let json = """
        {"events":[{"id":"pre1","date":"2026-06-06T00:30Z",
          "status":{"period":0,"type":{"state":"pre","shortDetail":"6/5 - 8:30 PM EDT"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"0","team":{"abbreviation":"SA"}},
            {"homeAway":"away","score":"0","team":{"abbreviation":"NY"}}
          ]}]}]}
        """
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))

        // The time suffix is rendered in the runner's local timezone, so only assert the
        // timezone-independent prefix here; the parsed instant is checked exactly below.
        XCTAssertTrue(
            mapped.displayString.hasPrefix("NY vs SA"),
            "unexpected display string: \(mapped.displayString)"
        )
        guard case .pre(let start) = mapped.state else { return XCTFail("expected .pre state") }
        XCTAssertEqual(start, utcDate(2026, 6, 6, 0, 30))
    }

    func testPreGameParsesWithSecondsISODate() throws {
        let json = """
        {"events":[{"id":"pre2","date":"2026-06-06T00:30:45Z",
          "status":{"period":0,"type":{"state":"pre"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"0","team":{"abbreviation":"SA"}},
            {"homeAway":"away","score":"0","team":{"abbreviation":"NY"}}
          ]}]}]}
        """
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))
        guard case .pre(let start) = mapped.state else { return XCTFail("expected .pre state") }
        XCTAssertEqual(start, utcDate(2026, 6, 6, 0, 30, 45))
    }

    // MARK: - Defensive degradation

    func testMissingScoresAndAbbreviationsDegradeGracefully() throws {
        let json = """
        {"events":[{"id":"sparse","status":{"displayClock":"","period":2,"type":{"state":"in"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","team":{}},
            {"homeAway":"away","team":{}}
          ]}]}]}
        """
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))
        // Missing scores default to "0", missing names to "—", empty clock is dropped.
        XCTAssertEqual(mapped.displayString, "— 0  — 0 · Q2")
    }

    func testEventWithFewerThanTwoCompetitorsIsDropped() throws {
        let json = """
        {"events":[{"id":"solo","competitions":[{"competitors":[
          {"homeAway":"home","score":"1","team":{"abbreviation":"A"}}
        ]}]}]}
        """
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        XCTAssertNil(adapter.map(try firstEvent(json)))
    }

    func testEventWithNoCompetitionsIsDropped() throws {
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        XCTAssertNil(adapter.map(try firstEvent(#"{"events":[{"id":"empty"}]}"#)))
    }

    // MARK: - Real captured ESPN payload

    func testDecodesAndMapsRealESPNPayloadFixture() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "nba_scoreboard", withExtension: "json", subdirectory: "Fixtures"
            ),
            "bundled fixture not found — check Package.swift resources"
        )
        let scoreboard = try JSONDecoder().decode(
            BasketballAdapter.Scoreboard.self, from: Data(contentsOf: url)
        )
        let events = try XCTUnwrap(scoreboard.events, "real payload had no events array")

        // Structural assertions only, so re-capturing the fixture on another day won't break
        // this: every decodable event maps to a non-empty, well-formed display string.
        let adapter = BasketballAdapter(league: nbaLeague, favorites: [])
        let mapped = events.compactMap(adapter.map)
        XCTAssertEqual(mapped.count, events.count, "a real event failed to map")
        for event in mapped {
            XCTAssertFalse(event.displayString.isEmpty)
        }
    }

    // MARK: - Helpers

    /// Builds an absolute `Date` from UTC components — timezone-independent, so assertions
    /// on parsed instants are stable across CI runners.
    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }
}
