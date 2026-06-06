import XCTest
@testable import MacSportsBar

/// Tests for `TeamDirectory.parse`, which turns ESPN's `/teams` payload into the picker model.
final class TeamDirectoryTests: XCTestCase {

    private func parse(_ json: String) throws -> [TeamInfo] {
        let payload = try JSONDecoder().decode(TeamsPayload.self, from: Data(json.utf8))
        return TeamDirectory.parse(payload)
    }

    func testExtractsTeamsWithLogos() throws {
        let teams = try parse("""
        {"sports":[{"leagues":[{"teams":[
          {"team":{"id":"1","abbreviation":"ATL","displayName":"Atlanta Hawks",
                   "logos":[{"href":"https://a.espncdn.com/i/teamlogos/nba/500/atl.png"}]}},
          {"team":{"id":"2","abbreviation":"BOS","displayName":"Boston Celtics",
                   "logos":[{"href":"https://a.espncdn.com/i/teamlogos/nba/500/bos.png"}]}}
        ]}]}]}
        """)
        XCTAssertEqual(teams.count, 2)
        XCTAssertEqual(teams[0], TeamInfo(
            id: "ATL", name: "Atlanta Hawks",
            logoURL: URL(string: "https://a.espncdn.com/i/teamlogos/nba/500/atl.png")))
        XCTAssertEqual(teams[1].id, "BOS")
    }

    func testSkipsTeamsWithoutAbbreviation() throws {
        let teams = try parse("""
        {"sports":[{"leagues":[{"teams":[
          {"team":{"displayName":"No Abbrev"}},
          {"team":{"abbreviation":"NY","displayName":"New York"}}
        ]}]}]}
        """)
        XCTAssertEqual(teams.map(\.id), ["NY"])
    }

    func testFallsBackToAbbreviationWhenNameMissing() throws {
        let teams = try parse(#"{"sports":[{"leagues":[{"teams":[{"team":{"abbreviation":"SA"}}]}]}]}"#)
        XCTAssertEqual(teams.first?.name, "SA")
        XCTAssertNil(teams.first?.logoURL)
    }

    func testEmptyPayloadYieldsNoTeams() throws {
        XCTAssertTrue(try parse("{}").isEmpty)
    }
}
