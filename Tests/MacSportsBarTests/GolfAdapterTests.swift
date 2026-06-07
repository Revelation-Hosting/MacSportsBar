import XCTest
@testable import MacSportsBar

/// Tests for `GolfAdapter`'s leaderboard formatting and its name/score helpers.
final class GolfAdapterTests: XCTestCase {

    private let pga = LeagueID(sport: "golf", league: "pga", displayName: "PGA")
    private func adapter(_ favorites: Set<String> = []) -> GolfAdapter {
        GolfAdapter(league: pga, favorites: favorites)
    }

    private func firstEvent(_ json: String) throws -> GolfAdapter.Scoreboard.Event {
        let board = try JSONDecoder().decode(GolfAdapter.Scoreboard.self, from: Data(json.utf8))
        return try XCTUnwrap(board.events?.first)
    }

    // MARK: - Helpers

    func testShortTournamentTrimsSponsorAndThe() {
        let a = adapter()
        XCTAssertEqual(a.shortTournament("the Memorial Tournament pres. by Workday"), "Memorial Tournament")
        XCTAssertEqual(a.shortTournament("The Genesis Invitational presented by Foo"), "Genesis Invitational")
        XCTAssertEqual(a.shortTournament("U.S. Open"), "U.S. Open")
    }

    func testLastName() {
        XCTAssertEqual(adapter().lastName("J.T. Poston"), "Poston")
        XCTAssertEqual(adapter().lastName("Scottie Scheffler"), "Scheffler")
    }

    func testFormatScore() {
        let a = adapter()
        XCTAssertEqual(a.formatScore("-9"), "−9")
        XCTAssertEqual(a.formatScore("E"), "E")
        XCTAssertEqual(a.formatScore("+2"), "+2")
    }

    // MARK: - Mapping

    func testLiveWithThru() throws {
        let json = """
        {"events":[{"id":"g1","name":"the Memorial Tournament pres. by Workday",
          "status":{"type":{"state":"in"}},
          "competitions":[{"status":{"period":4},"competitors":[
            {"order":1,"score":"-9","athlete":{"displayName":"J.T. Poston"},"status":{"thru":14}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter().map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "Memorial Tournament · Poston −9 thru 14")
        guard case .live = mapped.state else { return XCTFail("expected .live") }
    }

    func testLiveBetweenRoundsShowsRound() throws {
        let json = """
        {"events":[{"id":"g2","name":"the Memorial Tournament pres. by Workday",
          "status":{"type":{"state":"in"}},
          "competitions":[{"status":{"period":2},"competitors":[
            {"order":1,"score":"-9","athlete":{"displayName":"J.T. Poston"}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter().map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "Memorial Tournament · Poston −9 · R2")
    }

    func testFinalShowsWinner() throws {
        let json = """
        {"events":[{"id":"g3","name":"U.S. Open","status":{"type":{"state":"post"}},
          "competitions":[{"competitors":[
            {"order":1,"score":"-12","athlete":{"displayName":"Scottie Scheffler"}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter().map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "U.S. Open · Scheffler −12 · Final")
        guard case .final = mapped.state else { return XCTFail("expected .final") }
    }

    func testFavoriteLeaderGetsTopPriority() throws {
        let json = """
        {"events":[{"id":"g4","name":"U.S. Open","status":{"type":{"state":"in"}},
          "competitions":[{"status":{"period":3},"competitors":[
            {"order":1,"score":"-5","athlete":{"displayName":"Scottie Scheffler"},"status":{"thru":9}}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter(["scheffler"]).map(firstEvent(json)))
        XCTAssertTrue(mapped.isFavorite)
        XCTAssertEqual(mapped.sortPriority, 1000)
    }

    // MARK: - "thru N" derived from per-hole linescores (status.thru is null in real data)

    func testHolesThroughCountsCurrentRoundHoles() {
        let a = adapter()
        // 4 rounds; round 4 has 13 per-hole entries → thru 13.
        let player = GolfAdapter.Scoreboard.Competitor(
            order: 1, score: "-10", athlete: nil, status: nil,
            linescores: [round(1, holes: 18), round(2, holes: 18), round(3, holes: 18), round(4, holes: 13)])
        XCTAssertEqual(a.holesThrough(player, round: 4), 13)
        XCTAssertEqual(a.holesThrough(player, round: nil), 13, "defaults to the latest round")
        // A completed round → 18 (caller renders "F").
        let done = GolfAdapter.Scoreboard.Competitor(
            order: 1, score: "-10", athlete: nil, status: nil, linescores: [round(4, holes: 18)])
        XCTAssertEqual(a.holesThrough(done, round: 4), 18)
        // No linescores → nil (caller shows the round number).
        let empty = GolfAdapter.Scoreboard.Competitor(
            order: 1, score: "-10", athlete: nil, status: nil, linescores: nil)
        XCTAssertNil(a.holesThrough(empty, round: 4))
    }

    func testLiveThruFromRealFixture() throws {
        // Trimmed real capture of the 2026 Memorial final round: Burns leads −10, thru 13.
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "pga_live_leaderboard", withExtension: "json", subdirectory: "Fixtures"))
        let board = try JSONDecoder().decode(GolfAdapter.Scoreboard.self, from: Data(contentsOf: url))
        let mapped = try XCTUnwrap(adapter().map(try XCTUnwrap(board.events?.first)))
        XCTAssertEqual(mapped.displayString, "Memorial Tournament · Burns −10 thru 13")
    }

    func testFinishedLeaderShowsF() throws {
        // Leader has completed all 18 of the current round → "· F".
        let json = """
        {"events":[{"id":"g5","name":"U.S. Open","status":{"type":{"state":"in"}},
          "competitions":[{"status":{"period":4},"competitors":[
            {"order":1,"score":"-12","athlete":{"displayName":"Scottie Scheffler"},
             "linescores":[{"period":4,"linescores":[
               {},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}]}]}
          ]}]}]}
        """
        let mapped = try XCTUnwrap(adapter().map(firstEvent(json)))
        XCTAssertEqual(mapped.displayString, "U.S. Open · Scheffler −12 · F")
    }

    /// A round with `holes` blank per-hole entries.
    private func round(_ period: Int, holes: Int) -> GolfAdapter.Scoreboard.Linescore {
        .init(period: period, linescores: Array(repeating: .init(), count: holes))
    }
}
