import XCTest
@testable import MacSportsBar

/// Tests for the interleaved menu-bar readout, `AppModel.barText(for:)`: the dash format
/// `AWAY a - h HOME · detail` (so the score reads the same whether or not the color team logos
/// are interleaved around it), falling back to the event's own string when there's no matchup.
final class BarTextTests: XCTestCase {

    private let nba = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
    private let pga = LeagueID(sport: "golf", league: "pga", displayName: "PGA")

    private func event(_ state: SportEvent.State, matchup: SportEvent.Matchup?,
                       displayString: String) -> SportEvent {
        SportEvent(id: "x", league: nba, state: state, displayString: displayString,
                   isFavorite: false, sortPriority: 0, matchup: matchup)
    }

    func testLiveUsesDashScoreWithDetail() {
        let e = event(.live,
                      matchup: .init(away: "NY", awayScore: "39", home: "SA", homeScore: "42",
                                     detail: "7:01 Q2"),
                      displayString: "NY 39  SA 42 · 7:01 Q2")
        XCTAssertEqual(AppModel.barText(for: e), "NY 39 - 42 SA · 7:01 Q2")
    }

    func testFinalDashScore() {
        let e = event(.final,
                      matchup: .init(away: "NY", awayScore: "98", home: "SA", homeScore: "105",
                                     detail: "Final"),
                      displayString: "NY 98  SA 105 · Final")
        XCTAssertEqual(AppModel.barText(for: e), "NY 98 - 105 SA · Final")
    }

    func testUpcomingUsesVsWithoutScores() {
        let e = event(.pre(startDate: nil),
                      matchup: .init(away: "NY", awayScore: "", home: "SA", homeScore: "",
                                     detail: "Sat 5:00p"),
                      displayString: "NY vs SA · Sat 5:00p")
        XCTAssertEqual(AppModel.barText(for: e), "NY vs SA · Sat 5:00p")
    }

    func testEmptyDetailOmitsSeparator() {
        let e = event(.live,
                      matchup: .init(away: "NY", awayScore: "39", home: "SA", homeScore: "42",
                                     detail: ""),
                      displayString: "NY 39  SA 42")
        XCTAssertEqual(AppModel.barText(for: e), "NY 39 - 42 SA")
    }

    func testFallsBackToDisplayStringWhenNoMatchup() {
        // Golf/NASCAR are leaderboard/field shapes with no per-team matchup.
        let e = SportEvent(id: "g", league: pga, state: .live,
                           displayString: "Memorial · Poston −9 · R2",
                           isFavorite: false, sortPriority: 0)
        XCTAssertEqual(AppModel.barText(for: e), "Memorial · Poston −9 · R2")
    }

    // MARK: - fitMenuBar: drop the race name before clipping the lap/leader

    func testFitUsesFullWhenItFits() {
        let full = "Michigan · L63/200 · St2 18/75 · #77 Hocevar"  // 44 chars
        XCTAssertEqual(AppModel.fitMenuBar(full: full, short: "L63/200 · St2 18/75 · #77 Hocevar", limit: 50), full)
    }

    func testFitDropsRaceNameWhenTooLong() {
        // At the default 40 cap, drop "Michigan · " rather than clip "#77 Hocevar".
        let full = "Michigan · L63/200 · St2 18/75 · #77 Hocevar"   // 44
        let short = "L63/200 · St2 18/75 · #77 Hocevar"             // 33
        XCTAssertEqual(AppModel.fitMenuBar(full: full, short: short, limit: 40), short)
    }

    func testFitHardClipsCompactOnlyAsLastResort() {
        let full = "Michigan · L63/200 · St2 18/75 · #77 Hocevar"
        let short = "L63/200 · St2 18/75 · #77 Hocevar"             // 33
        // Even the compact form exceeds a very tight cap → ellipsis on the compact one.
        XCTAssertEqual(AppModel.fitMenuBar(full: full, short: short, limit: 20),
                       AppModel.truncate(short, limit: 20))
    }

    func testFitWithoutCompactBehavesLikePlainTruncate() {
        let full = "GONZ 72  UCLA 68 · 4:32 2H is a long one here"
        XCTAssertEqual(AppModel.fitMenuBar(full: full, short: nil, limit: 25),
                       AppModel.truncate(full, limit: 25))
    }
}
