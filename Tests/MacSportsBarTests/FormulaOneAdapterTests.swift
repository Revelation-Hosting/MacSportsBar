import XCTest
@testable import MacSportsBar

/// Tests for `FormulaOneAdapter`. The fixtures are trimmed real ESPN payloads captured during the
/// 2026 Hungaroring weekend (in-progress), the completed Belgian GP, and the cancelled Bahrain GP
/// — the last two of which encode the traps this adapter exists to guard against.
final class FormulaOneAdapterTests: XCTestCase {

    private let f1 = LeagueID(sport: "racing", league: "f1", displayName: "Formula 1")
    private func adapter(_ favorites: Set<String> = []) -> FormulaOneAdapter {
        FormulaOneAdapter(league: f1, favorites: favorites)
    }

    private func fixture(_ name: String) throws -> FormulaOneAdapter.Scoreboard.Event {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "bundled fixture \(name) not found — check Package.swift resources")
        let board = try JSONDecoder().decode(
            FormulaOneAdapter.Scoreboard.self, from: Data(contentsOf: url))
        return try XCTUnwrap(board.events?.first)
    }

    /// The real 2026 grid, keyed the way the adapter looks constructors up.
    private var teams: [String: F1Constructor] {
        ["antonelli": F1Constructor(name: "Mercedes", colorHex: "00D7B6"),
         "norris": F1Constructor(name: "McLaren", colorHex: "F47600")]
    }

    // MARK: - Trap 1: the event-level status lies on a live weekend

    func testIgnoresLyingEventStatusAndUsesPerSessionStatus() throws {
        // ESPN reports the EVENT as STATUS_FINAL/post/completed while qualifying and the race are
        // still scheduled two days out. Every emitted session must follow its own status.
        let event = try fixture("f1_weekend_in_progress")
        XCTAssertEqual(event.status?.type?.state, "post", "fixture must preserve the lying status")

        let mapped = adapter().map(event, constructors: teams)
        let race = try XCTUnwrap(mapped.first { $0.id.hasSuffix("-Race") })
        guard case .pre = race.state else {
            return XCTFail("the race is scheduled for tomorrow — must not be final")
        }
        let qualifying = try XCTUnwrap(mapped.first { $0.id.hasSuffix("-Qual") })
        guard case .pre = qualifying.state else { return XCTFail("qualifying must still be pre") }
        XCTAssertFalse(mapped.contains { $0.isFinal }, "no session on this weekend has finished")
    }

    // MARK: - Trap 2: a cancelled Grand Prix is state "post"

    func testCanceledGrandPrixEmitsNothing() throws {
        let event = try fixture("f1_weekend_canceled")
        XCTAssertEqual(event.status?.type?.name, "STATUS_CANCELED")
        XCTAssertTrue(adapter().map(event, constructors: teams).isEmpty,
                      "a cancelled GP must not render as a finished race")
    }

    func testIsCanceledClassifier() {
        func status(_ name: String?, _ state: String?, _ completed: Bool?) -> FormulaOneAdapter.Scoreboard.Status {
            .init(period: nil, type: .init(name: name, state: state, completed: completed,
                                           description: nil, shortDetail: nil))
        }
        XCTAssertTrue(FormulaOneAdapter.isCanceled(status("STATUS_CANCELED", "post", false)))
        XCTAssertTrue(FormulaOneAdapter.isCanceled(status(nil, "post", false)), "post but not completed")
        XCTAssertFalse(FormulaOneAdapter.isCanceled(status("STATUS_FINAL", "post", true)))
        XCTAssertFalse(FormulaOneAdapter.isCanceled(status("STATUS_SCHEDULED", "pre", false)))
        XCTAssertFalse(FormulaOneAdapter.isCanceled(nil))
    }

    // MARK: - Sessions

    func testSkipsPracticeAndEmitsQualifyingAndRace() throws {
        let mapped = adapter().map(try fixture("f1_weekend_in_progress"), constructors: teams)
        let ids = mapped.map(\.id)
        XCTAssertFalse(ids.contains { $0.contains("FP") }, "practice sessions are skipped")
        XCTAssertTrue(ids.contains { $0.hasSuffix("-Qual") })
        XCTAssertTrue(ids.contains { $0.hasSuffix("-Race") })
        XCTAssertEqual(mapped.count, 2, "one event per notable session, practice excluded")
    }

    func testUpcomingSessionReadout() throws {
        let mapped = adapter().map(try fixture("f1_weekend_in_progress"), constructors: teams)
        let qualifying = try XCTUnwrap(mapped.first { $0.id.hasSuffix("-Qual") })
        XCTAssertTrue(qualifying.displayString.hasPrefix("Hungary GP · Qualifying · "),
                      "got \(qualifying.displayString)")
        XCTAssertNotNil(qualifying.date, "date drives the poll ramp and the ±24h window")
        XCTAssertEqual(qualifying.menuShort?.hasPrefix("Qualifying · "), true,
                       "compact form drops the Grand Prix name first")
    }

    func testFinishedRaceCreditsWinnerAndConstructor() throws {
        let mapped = adapter().map(try fixture("f1_weekend_complete"), constructors: teams)
        let race = try XCTUnwrap(mapped.first { $0.id.hasSuffix("-Race") })
        XCTAssertEqual(race.displayString, "Belgium GP · Antonelli won (Mercedes)")
        XCTAssertEqual(race.menuShort, "Antonelli won (Mercedes)")
        XCTAssertEqual(race.accentHex, "00D7B6", "the glyph tints to the winning constructor")
        XCTAssertTrue(race.isFinal)
    }

    func testFinishedQualifyingNamesTheSessionAndDoesNotSayWon() throws {
        let mapped = adapter().map(try fixture("f1_weekend_complete"), constructors: teams)
        let qualifying = try XCTUnwrap(mapped.first { $0.id.hasSuffix("-Qual") })
        XCTAssertTrue(qualifying.displayString.contains("Qualifying · "), qualifying.displayString)
        XCTAssertFalse(qualifying.displayString.contains("won"), "only the race is won")
    }

    func testDegradesGracefullyWithoutConstructors() throws {
        // OpenF1 unreachable → still a useful readout, just no team.
        let mapped = adapter().map(try fixture("f1_weekend_complete"), constructors: [:])
        let race = try XCTUnwrap(mapped.first { $0.id.hasSuffix("-Race") })
        XCTAssertEqual(race.displayString, "Belgium GP · Antonelli won")
        XCTAssertNil(race.accentHex)
    }

    // MARK: - Helpers

    func testGrandPrixNameUsesCircuitCountryNotTheSponsor() throws {
        // ESPN's name/shortName carry a rotating sponsor ("Moët & Chandon Belgian GP").
        let event = try fixture("f1_weekend_complete")
        XCTAssertTrue((event.shortName ?? "").contains("Moët"), "fixture keeps the sponsor prefix")
        XCTAssertEqual(FormulaOneAdapter.grandPrixName(event), "Belgium GP")
    }

    func testSessionLabels() {
        XCTAssertEqual(FormulaOneAdapter.sessionLabel("Qual"), "Qualifying")
        XCTAssertEqual(FormulaOneAdapter.sessionLabel("Race"), "Race")
        XCTAssertEqual(FormulaOneAdapter.sessionLabel("Sprint"), "Sprint")
        XCTAssertEqual(FormulaOneAdapter.sessionLabel("Xyz"), "Xyz", "unknown sessions pass through")
        XCTAssertTrue(FormulaOneAdapter.isPractice("FP3"))
        XCTAssertFalse(FormulaOneAdapter.isPractice("Qual"))
    }

    func testCreditFormatting() {
        let mclaren = F1Constructor(name: "McLaren", colorHex: "F47600")
        XCTAssertEqual(FormulaOneAdapter.credit(driver: "Norris", team: mclaren, won: true),
                       "Norris won (McLaren)")
        XCTAssertEqual(FormulaOneAdapter.credit(driver: "Norris", team: mclaren, won: false),
                       "Norris (McLaren)")
        XCTAssertEqual(FormulaOneAdapter.credit(driver: "Norris", team: nil, won: true), "Norris won")
        XCTAssertEqual(FormulaOneAdapter.credit(driver: "", team: mclaren, won: true), "Final")
    }

    func testLastNameSkipsSuffix() {
        XCTAssertEqual(FormulaOneAdapter.lastName("Kimi Antonelli"), "Antonelli")
        XCTAssertEqual(FormulaOneAdapter.lastName("Max Verstappen"), "Verstappen")
    }

    func testFavoriteDriverGetsTopPriority() throws {
        let mapped = adapter(["antonelli"]).map(try fixture("f1_weekend_complete"), constructors: teams)
        let race = try XCTUnwrap(mapped.first { $0.id.hasSuffix("-Race") })
        XCTAssertTrue(race.isFavorite)
        XCTAssertEqual(race.sortPriority, 300, "a finished favorite outranks a plain final")
    }

    func testRegisteredInCatalogAsRacing() {
        let entry = LeagueCatalog.all.first { $0.league.league == "f1" }
        XCTAssertNotNil(entry, "Formula 1 must be registered")
        XCTAssertEqual(entry?.league.sport, "racing", "so it inherits the flag glyph + follow-series UI")
        XCTAssertEqual(entry?.league.displayName, "Formula 1")
    }
}
