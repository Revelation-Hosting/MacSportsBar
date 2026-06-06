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
}
