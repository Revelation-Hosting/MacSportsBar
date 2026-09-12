import XCTest
@testable import MacSportsBar

/// Tests for `Favorites`, the split between exact team picks and free-form tokens. Regression
/// for the picker bug where choosing Washington ("wash") also lit up Washington State, because
/// picks were merged into the token set and substring-matched like free text.
final class FavoritesMatchingTests: XCTestCase {

    private let huskies: [String?] = ["WASH", "Washington Huskies", "Washington", "Washington"]
    private let cougars: [String?] = ["WSU", "Washington State Cougars", "Washington State", "Washington State"]

    func testTeamPickMatchesOnlyItsAbbreviation() {
        let favorites = Favorites(teams: ["wash"])
        XCTAssertTrue(favorites.matchesTeam(abbreviation: "WASH", names: huskies))
        XCTAssertFalse(favorites.matchesTeam(abbreviation: "WSU", names: cougars),
                       "a pick must never substring-match another team's name")
    }

    func testTokenStillMatchesBySubstring() {
        // Free text is deliberately fuzzy: "washington" is meant to catch both.
        let favorites = Favorites(tokens: ["washington"])
        XCTAssertTrue(favorites.matchesTeam(abbreviation: "WASH", names: huskies))
        XCTAssertTrue(favorites.matchesTeam(abbreviation: "WSU", names: cougars))
    }

    func testEmptyMatchesNothing() {
        XCTAssertTrue(Favorites.none.isEmpty)
        XCTAssertFalse(Favorites.none.matchesTeam(abbreviation: "WASH", names: huskies))
        XCTAssertFalse(Favorites(teams: ["wash"]).matchesTeam(abbreviation: nil, names: huskies),
                       "a pick needs the feed's abbreviation to match against")
    }

    func testHeadToHeadAdapterHonorsTheSplit() throws {
        let ncaaf = LeagueID(sport: "football", league: "college-football", displayName: "NCAAF")
        let adapter = HeadToHeadAdapter(league: ncaaf, favorites: [], teams: ["wash"], style: .quarters)
        let board = try JSONDecoder().decode(HeadToHeadAdapter.Scoreboard.self, from: Data("""
        {"events":[
          {"id":"1","status":{"type":{"state":"post"}},"competitions":[{"competitors":[
            {"homeAway":"home","score":"34","team":{"abbreviation":"KSU","displayName":"Kansas State Wildcats","location":"Kansas State"}},
            {"homeAway":"away","score":"7","team":{"abbreviation":"WSU","displayName":"Washington State Cougars","location":"Washington State"}}
          ]}]},
          {"id":"2","status":{"type":{"state":"post"}},"competitions":[{"competitors":[
            {"homeAway":"home","score":"16","team":{"abbreviation":"WASH","displayName":"Washington Huskies","location":"Washington"}},
            {"homeAway":"away","score":"14","team":{"abbreviation":"USU","displayName":"Utah State Aggies","location":"Utah State"}}
          ]}]}
        ]}
        """.utf8))
        let events = try XCTUnwrap(board.events).compactMap(adapter.map)
        XCTAssertEqual(events.map(\.isFavorite), [false, true])
    }

    func testCatalogPassesPicksAndTokensSeparately() throws {
        // Through the real factory: a "wash" pick must not make WSU a favorite.
        let ncaaf = try XCTUnwrap(LeagueCatalog.all.first { $0.id == "college-football" })
        let adapter = try XCTUnwrap(ncaaf.makeAdapter(Favorites(teams: ["wash"])) as? HeadToHeadAdapter)
        XCTAssertEqual(adapter.teams, ["wash"])
        XCTAssertTrue(adapter.favorites.isEmpty)
    }

    // MARK: - Filter labels speak the sport's language

    func testAllLabelUsesTheSportsNoun() {
        let nascar = LeagueID(sport: "racing", league: "nascar-premier", displayName: "NASCAR")
        let pga = LeagueID(sport: "golf", league: "pga", displayName: "PGA")
        let epl = LeagueID(sport: "soccer", league: "eng.1", displayName: "Premier League")
        let nba = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
        XCTAssertEqual(LeagueFilter.all.label(for: nascar), "All races")
        XCTAssertEqual(LeagueFilter.all.label(for: pga), "All tournaments")
        XCTAssertEqual(LeagueFilter.all.label(for: epl), "All matches")
        XCTAssertEqual(LeagueFilter.all.label(for: nba), "All games")
        XCTAssertEqual(LeagueFilter.favorites.label(for: nascar), "Favorites only")
    }
}
