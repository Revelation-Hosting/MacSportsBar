import XCTest
@testable import MacSportsBar

/// Tests for `BaseballAdapter`'s decode → map → format path, including base/out state.
final class BaseballAdapterTests: XCTestCase {

    private let mlb = LeagueID(sport: "baseball", league: "mlb", displayName: "MLB")

    private func firstEvent(_ json: String) throws -> BaseballAdapter.Scoreboard.Event {
        let board = try JSONDecoder().decode(BaseballAdapter.Scoreboard.self, from: Data(json.utf8))
        return try XCTUnwrap(board.events?.first)
    }

    // MARK: - Live formatting with base/out state

    func testLiveActiveHalfShowsInningOutsAndBases() throws {
        let json = """
        {"events":[{"id":"mlb1","status":{"period":7,"type":{"state":"in","shortDetail":"Bottom 7th"}},
          "competitions":[{"situation":{"outs":2,"onFirst":true,"onSecond":false,"onThird":true},
            "competitors":[
              {"homeAway":"home","score":"2","team":{"abbreviation":"TEX"}},
              {"homeAway":"away","score":"3","team":{"abbreviation":"SEA"}}
            ]}]}]}
        """
        let adapter = BaseballAdapter(league: mlb, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "SEA 3  TEX 2 · Bot 7th · 2 out · [1_3]")
        guard case .live = mapped.state else { return XCTFail("expected .live") }
    }

    func testBetweenInningsDropsOutsAndBases() throws {
        let json = """
        {"events":[{"id":"mlb2","status":{"period":1,"type":{"state":"in","shortDetail":"End 1st"}},
          "competitions":[{"situation":{"outs":0,"onFirst":false,"onSecond":false,"onThird":false},
            "competitors":[
              {"homeAway":"home","score":"0","team":{"abbreviation":"PHI"}},
              {"homeAway":"away","score":"0","team":{"abbreviation":"CHW"}}
            ]}]}]}
        """
        let adapter = BaseballAdapter(league: mlb, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "CHW 0  PHI 0 · End 1st")
    }

    func testFinalFormatting() throws {
        let json = """
        {"events":[{"id":"mlb3","status":{"type":{"state":"post"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"2","team":{"abbreviation":"TEX"}},
            {"homeAway":"away","score":"5","team":{"abbreviation":"SEA"}}
          ]}]}]}
        """
        let adapter = BaseballAdapter(league: mlb, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "SEA 5  TEX 2 · Final")
        guard case .final = mapped.state else { return XCTFail("expected .final") }
    }

    func testPreFormattingPrefix() throws {
        let json = """
        {"events":[{"id":"mlb4","date":"2026-06-06T00:30Z","status":{"type":{"state":"pre"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"0","team":{"abbreviation":"TEX"}},
            {"homeAway":"away","score":"0","team":{"abbreviation":"SEA"}}
          ]}]}]}
        """
        let adapter = BaseballAdapter(league: mlb, favorites: [])
        let mapped = try XCTUnwrap(adapter.map(firstEvent(json)))
        XCTAssertTrue(mapped.displayString.hasPrefix("SEA vs TEX"), mapped.displayString)
        guard case .pre = mapped.state else { return XCTFail("expected .pre") }
    }

    // MARK: - Base glyph

    func testBasesGlyph() {
        let adapter = BaseballAdapter(league: mlb, favorites: [])
        func glyph(_ first: Bool, _ second: Bool, _ third: Bool) -> String {
            adapter.basesGlyph(.init(balls: nil, strikes: nil, outs: nil,
                                     onFirst: first, onSecond: second, onThird: third))
        }
        XCTAssertEqual(glyph(false, false, false), "[___]")
        XCTAssertEqual(glyph(true, false, true), "[1_3]")
        XCTAssertEqual(glyph(true, true, true), "[123]")
        XCTAssertEqual(glyph(false, true, false), "[_2_]")
    }

    // MARK: - Favorites + defensive

    func testFavoriteMatchesShortName() throws {
        let json = """
        {"events":[{"id":"f","status":{"type":{"state":"in","shortDetail":"Top 3rd"}},
          "competitions":[{"situation":{"outs":1},"competitors":[
            {"homeAway":"home","score":"1","team":{"abbreviation":"SEA","shortDisplayName":"Mariners"}},
            {"homeAway":"away","score":"0","team":{"abbreviation":"TEX"}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(BaseballAdapter(league: mlb, favorites: ["mariners"]).map(firstEvent(json)))
        XCTAssertTrue(mapped.isFavorite)
        XCTAssertEqual(mapped.sortPriority, 1000)
    }

    func testMissingFieldsDegradeGracefully() throws {
        let json = """
        {"events":[{"id":"sparse","status":{"period":3,"type":{"state":"in"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","team":{}},
            {"homeAway":"away","team":{}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(BaseballAdapter(league: mlb, favorites: []).map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "— 0  — 0 · Inning 3")
    }
}
