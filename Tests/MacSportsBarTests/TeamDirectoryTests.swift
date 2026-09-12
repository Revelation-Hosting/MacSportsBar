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

    func testSortsByDisplayName() throws {
        // ESPN orders by slug, which puts "Arizona State" ahead of "Arizona"; a 700-team
        // college list needs to read alphabetically.
        let teams = try parse("""
        {"sports":[{"leagues":[{"teams":[
          {"team":{"abbreviation":"ASU","displayName":"Arizona State Sun Devils"}},
          {"team":{"abbreviation":"ARIZ","displayName":"Arizona Wildcats"}},
          {"team":{"abbreviation":"AMH","displayName":"Amherst Mammoths"}}
        ]}]}]}
        """)
        XCTAssertEqual(teams.map(\.id), ["AMH", "ASU", "ARIZ"])
    }

    // MARK: - Picker search

    private let big = [
        TeamInfo(id: "MICH", name: "Michigan Wolverines", logoURL: nil),
        TeamInfo(id: "MSU", name: "Michigan State Spartans", logoURL: nil),
        TeamInfo(id: "OSU", name: "Ohio State Buckeyes", logoURL: nil),
    ]

    func testFilterMatchesNameCaseInsensitively() {
        XCTAssertEqual(TeamDirectory.filter(big, query: "michigan").map(\.id), ["MICH", "MSU"])
        XCTAssertEqual(TeamDirectory.filter(big, query: "  State ").map(\.id), ["MSU", "OSU"])
    }

    func testFilterMatchesAbbreviation() {
        XCTAssertEqual(TeamDirectory.filter(big, query: "osu").map(\.id), ["OSU"])
    }

    func testBlankQueryKeepsEverything() {
        XCTAssertEqual(TeamDirectory.filter(big, query: "   ").count, 3)
        XCTAssertTrue(TeamDirectory.filter(big, query: "zzz").isEmpty)
    }

    // MARK: - Row cap (don't mount 700 logo rows at once)

    private let many = (1...100).map {
        TeamInfo(id: "T\($0)", name: String(format: "Team %03d", $0), logoURL: nil)
    }

    func testUnderCapShowsEverything() {
        let result = TeamDirectory.visible(big, query: "", selected: [], cap: 50)
        XCTAssertEqual(result.shown.count, 3)
        XCTAssertEqual(result.hidden, 0)
    }

    func testOverCapTruncatesAndCounts() {
        let result = TeamDirectory.visible(many, query: "", selected: [], cap: 50)
        XCTAssertEqual(result.shown.map(\.id).first, "T1")
        XCTAssertEqual(result.shown.count, 50)
        XCTAssertEqual(result.hidden, 50)
    }

    func testSelectedTeamsAlwaysSurfaceFirst() {
        // A pick past the cap (T99) must still be visible so it can be unchecked — and it
        // leads the list. Selection is keyed by lowercased abbreviation, like `Settings`.
        let result = TeamDirectory.visible(many, query: "", selected: ["t99"], cap: 50)
        XCTAssertEqual(result.shown.first?.id, "T99")
        XCTAssertEqual(result.shown.count, 50)
        XCTAssertEqual(result.hidden, 50)
        XCTAssertFalse(result.shown.map(\.id).contains("T50"), "the cap still holds")
    }

    func testCapAppliesToSearchMatchesToo() {
        let result = TeamDirectory.visible(many, query: "Team 0", selected: [], cap: 10)
        XCTAssertEqual(result.shown.count, 10)
        XCTAssertEqual(result.hidden, 89, "'Team 0' matches 001–099")
    }
}
