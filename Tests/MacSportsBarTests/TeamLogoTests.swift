import XCTest
@testable import MacSportsBar

/// Tests that live events carry the matchup's team logo URLs (for the menu-bar logos option),
/// and that non-live events don't.
final class TeamLogoTests: XCTestCase {

    private func decodeFirst(_ json: String) throws -> HeadToHeadAdapter.Scoreboard.Event {
        let board = try JSONDecoder().decode(HeadToHeadAdapter.Scoreboard.self, from: Data(json.utf8))
        return try XCTUnwrap(board.events?.first)
    }

    func testLiveSetsTeamLogosFromScoreboard() throws {
        let adapter = HeadToHeadAdapter(
            league: LeagueID(sport: "football", league: "nfl", displayName: "NFL"),
            favorites: [], style: .quarters)
        let event = try decodeFirst("""
        {"events":[{"id":"nfl","status":{"displayClock":"7:30","period":3,"type":{"state":"in"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"21","team":{"abbreviation":"SEA","logo":"https://a.espncdn.com/sea.png"}},
            {"homeAway":"away","score":"14","team":{"abbreviation":"NE","logo":"https://a.espncdn.com/ne.png"}}
          ]}]}]}
        """)
        let mapped = try XCTUnwrap(adapter.map(event))
        XCTAssertEqual(mapped.awayLogo, URL(string: "https://a.espncdn.com/ne.png"))
        XCTAssertEqual(mapped.homeLogo, URL(string: "https://a.espncdn.com/sea.png"))

        // Per-team breakdown for the interleaved logo layout.
        let matchup = try XCTUnwrap(mapped.matchup)
        XCTAssertEqual(matchup.away, "NE")
        XCTAssertEqual(matchup.awayScore, "14")
        XCTAssertEqual(matchup.home, "SEA")
        XCTAssertEqual(matchup.homeScore, "21")
        XCTAssertEqual(matchup.detail, "7:30 Q3")
    }

    func testFinalHasNoLogos() throws {
        let adapter = HeadToHeadAdapter(
            league: LeagueID(sport: "hockey", league: "nhl", displayName: "NHL"),
            favorites: [], style: .hockey)
        let event = try decodeFirst("""
        {"events":[{"id":"f","status":{"type":{"state":"post"}},
          "competitions":[{"competitors":[
            {"homeAway":"home","score":"1","team":{"abbreviation":"VGK","logo":"https://x/vgk.png"}},
            {"homeAway":"away","score":"2","team":{"abbreviation":"CAR","logo":"https://x/car.png"}}
          ]}]}]}
        """)
        let mapped = try XCTUnwrap(adapter.map(event))
        XCTAssertNil(mapped.awayLogo)
        XCTAssertNil(mapped.homeLogo)
        XCTAssertNil(mapped.matchup)
    }
}
