import XCTest
@testable import MacSportsBar

/// The FIFA World Cup is just the generic soccer `HeadToHeadAdapter` pointed at ESPN's
/// `fifa.world` slug — verify it's registered as a soccer league and that a real World Cup
/// payload decodes + formats through it (fixture captured during the 2026 tournament).
final class WorldCupTests: XCTestCase {

    func testWorldCupRegisteredAsSoccer() {
        let wc = LeagueCatalog.all.first { $0.league.league == "fifa.world" }
        XCTAssertNotNil(wc, "World Cup (fifa.world) must be in the catalog")
        XCTAssertEqual(wc?.league.sport, "soccer")
        XCTAssertEqual(wc?.league.displayName, "World Cup")
    }

    func testMapsRealWorldCupFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "worldcup_scoreboard", withExtension: "json", subdirectory: "Fixtures"))
        let board = try JSONDecoder().decode(
            HeadToHeadAdapter.Scoreboard.self, from: Data(contentsOf: url))
        let events = try XCTUnwrap(board.events, "fixture had no events")

        let wc = LeagueID(sport: "soccer", league: "fifa.world", displayName: "World Cup")
        let adapter = HeadToHeadAdapter(league: wc, favorites: [], style: .soccer)
        let mapped = events.compactMap(adapter.map)

        XCTAssertFalse(mapped.isEmpty, "real World Cup events should map")
        for event in mapped {
            XCTAssertFalse(event.displayString.isEmpty, "every World Cup readout is non-empty")
            XCTAssertEqual(event.league.league, "fifa.world")
        }
    }
}
