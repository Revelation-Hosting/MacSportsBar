import XCTest
@testable import MacSportsBar

/// Tests for Formula 1 live timing. The fixture is a **real snapshot** captured from F1's own
/// SignalR Core feed (unauthenticated) after the 2026 Hungaroring Practice 2 session — which
/// makes it perfect for the most important test here: proving we refuse to render a stale
/// snapshot as live.
final class F1LiveTimingTests: XCTestCase {

    private let f1 = LeagueID(sport: "racing", league: "f1", displayName: "Formula 1")

    private func snapshot() throws -> F1LiveSnapshot {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "f1_live_snapshot", withExtension: "json", subdirectory: "Fixtures"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return F1LiveSnapshot(raw: try XCTUnwrap(object as? [String: Any]))
    }

    /// The captured snapshot's own heartbeat — "now" for the purposes of liveness tests.
    private var captureTime: Date {
        F1LiveSnapshot.parseDate("2026-07-24T16:28:32.4080704Z")!
    }

    // MARK: - Liveness (the snapshot lies between sessions)

    func testStaleSnapshotIsNotLive() throws {
        // F1 serves the last session's frozen state indefinitely. A day later it must not render.
        let aDayLater = captureTime.addingTimeInterval(24 * 3600)
        XCTAssertFalse(try snapshot().isLive(now: aDayLater),
                       "a day-old heartbeat must never be treated as live")
    }

    func testFinishedSessionIsNotLiveEvenWithFreshHeartbeat() throws {
        // The fixture's SessionStatus is Finished/Ends — belt and braces alongside the heartbeat.
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.sessionStarted, "Finished")
        XCTAssertFalse(snapshot.isLive(now: captureTime.addingTimeInterval(5)),
                       "a finished session is not live no matter how fresh the heartbeat")
    }

    func testLiveRequiresBothFreshHeartbeatAndRunningStatus() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func make(status: String, started: String, ageSeconds: TimeInterval) -> F1LiveSnapshot {
            F1LiveSnapshot(raw: [
                "Heartbeat": ["Utc": iso.string(from: now.addingTimeInterval(-ageSeconds))],
                "SessionStatus": ["Status": status, "Started": started],
                "SessionInfo": ["Name": "Qualifying"],
            ])
        }
        XCTAssertTrue(make(status: "Started", started: "Started", ageSeconds: 5).isLive(now: now))
        XCTAssertFalse(make(status: "Started", started: "Started", ageSeconds: 600).isLive(now: now),
                       "stale heartbeat")
        XCTAssertFalse(make(status: "Finished", started: "Finished", ageSeconds: 5).isLive(now: now),
                       "finished session")
    }

    // MARK: - Decoding the real snapshot

    func testDecodesSessionIdentityAndDriversFromRealSnapshot() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.countryName, "Hungary")
        XCTAssertEqual(snapshot.sessionName, "Practice 2")
        XCTAssertEqual(snapshot.meetingName, "Hungarian Grand Prix")

        // DriverList carries team + livery — this is what makes OpenF1 unnecessary for F1.
        let drivers = snapshot.drivers
        XCTAssertGreaterThanOrEqual(drivers.count, 20, "a full grid")
        let norris = drivers.values.first { $0.tla == "NOR" }
        XCTAssertEqual(norris?.team, "McLaren")
        XCTAssertEqual(norris?.colour, "F47600", "McLaren papaya, straight from F1")
        XCTAssertTrue(drivers.values.contains { $0.team == "Audi" }, "2026 grid")
    }

    func testReadsTrackStatusFlagFromRealSnapshot() throws {
        XCTAssertEqual(try snapshot().flag, .green, "fixture was captured under AllClear")
    }

    func testLeaderIsResolvedFromTimingData() throws {
        let snapshot = try snapshot()
        let leader = try XCTUnwrap(snapshot.leaderNumber, "someone is classified P1")
        XCTAssertNotNil(snapshot.drivers[leader], "the P1 number resolves to a driver")
    }

    // MARK: - TrackStatus → RaceFlag

    func testTrackStatusMapping() {
        XCTAssertEqual(RaceFlag(trackStatus: "1"), .green)
        XCTAssertEqual(RaceFlag(trackStatus: "2"), .caution)
        XCTAssertEqual(RaceFlag(trackStatus: "4"), .safetyCar)
        XCTAssertEqual(RaceFlag(trackStatus: "5"), .red)
        XCTAssertEqual(RaceFlag(trackStatus: "6"), .virtualSafetyCar, "VSC deployed")
        XCTAssertEqual(RaceFlag(trackStatus: "7"), .virtualSafetyCar, "VSC ending")
        XCTAssertNil(RaceFlag(trackStatus: "99"))
        XCTAssertNil(RaceFlag(trackStatus: nil))
    }

    func testSafetyCarAndVSCFlyTheYellowFlagAndAreNamedInText() {
        // Both are cautions, so both show the same yellow flag as any other caution — the
        // readout's "SC" / "VSC" carries the distinction, not the glyph.
        XCTAssertEqual(AppModel.flagGlyph(.safetyCar).symbol, AppModel.flagGlyph(.caution).symbol)
        XCTAssertEqual(AppModel.flagGlyph(.virtualSafetyCar).symbol, AppModel.flagGlyph(.caution).symbol)
        XCTAssertNotNil(AppModel.flagGlyph(.safetyCar).color)
        XCTAssertNotNil(AppModel.flagGlyph(.virtualSafetyCar).color)
        XCTAssertEqual(RaceFlag.safetyCar.shortLabel, "SC")
        XCTAssertEqual(RaceFlag.virtualSafetyCar.shortLabel, "VSC")
        XCTAssertNil(RaceFlag.green.shortLabel, "green needs no word")
    }

    // MARK: - Live readout

    private func liveSnapshot(session: String, trackStatus: String,
                              lap: Int? = nil, total: Int? = nil, phase: Int? = nil) -> F1LiveSnapshot {
        var raw: [String: Any] = [
            "SessionInfo": ["Name": session, "Meeting": ["Name": "Hungarian Grand Prix",
                                                         "Country": ["Name": "Hungary"]]],
            "TrackStatus": ["Status": trackStatus],
            "DriverList": ["4": ["Tla": "NOR", "TeamName": "McLaren", "TeamColour": "F47600"]],
            "TimingData": ["Lines": ["4": ["Position": "1"]]],
        ]
        if let lap { raw["LapCount"] = ["CurrentLap": lap, "TotalLaps": total as Any] }
        if let phase { raw["SessionData"] = ["Series": [["QualifyingPart": phase]]] }
        return F1LiveSnapshot(raw: raw)
    }

    func testRaceReadoutUnderSafetyCar() throws {
        let live = try XCTUnwrap(FormulaOneAdapter.liveReadout(
            from: liveSnapshot(session: "Race", trackStatus: "4", lap: 32, total: 70)))
        XCTAssertEqual(live.detail, "L32/70 · SC · NOR (McLaren)")
        XCTAssertEqual(live.flag, .safetyCar)
        XCTAssertEqual(live.accentHex, "F47600")
        XCTAssertTrue(live.isRace)
    }

    func testQualifyingReadoutShowsPhase() throws {
        let live = try XCTUnwrap(FormulaOneAdapter.liveReadout(
            from: liveSnapshot(session: "Qualifying", trackStatus: "1", phase: 2)))
        XCTAssertEqual(live.detail, "Q2 · NOR (McLaren)", "green needs no flag word")
        XCTAssertFalse(live.isRace)
    }

    func testQualifyingRedFlagged() throws {
        let live = try XCTUnwrap(FormulaOneAdapter.liveReadout(
            from: liveSnapshot(session: "Qualifying", trackStatus: "5", phase: 3)))
        XCTAssertEqual(live.detail, "Q3 · RED · NOR (McLaren)")
        XCTAssertEqual(live.flag, .red)
    }

    func testVirtualSafetyCarReadout() throws {
        let live = try XCTUnwrap(FormulaOneAdapter.liveReadout(
            from: liveSnapshot(session: "Race", trackStatus: "6", lap: 12, total: 70)))
        XCTAssertEqual(live.detail, "L12/70 · VSC · NOR (McLaren)")
    }

    func testLiveOverlayReplacesTheScheduledSession() throws {
        let scheduled = SportEvent(
            id: "600057440-Race", league: f1, state: .pre(startDate: nil),
            displayString: "Hungary GP · Race · Sun 6:00a", isFavorite: true, sortPriority: 600)
        let live = try XCTUnwrap(FormulaOneAdapter.liveReadout(
            from: liveSnapshot(session: "Race", trackStatus: "1", lap: 5, total: 70)))
        XCTAssertTrue(FormulaOneAdapter.matches(event: scheduled, live: live))

        let applied = FormulaOneAdapter.applyLive(live, to: scheduled)
        XCTAssertTrue(applied.isLive)
        XCTAssertEqual(applied.id, "600057440-Race", "keeps ESPN's id so notifications track it")
        XCTAssertEqual(applied.displayString, "Hungary GP · L5/70 · NOR (McLaren)")
        XCTAssertEqual(applied.sortPriority, 1000, "a live favorite outranks everything")
    }

    // MARK: - Constructor logos (hotlinked from F1's own CDN)

    func testConstructorLogoURLsForTheWholeGrid() {
        // The slug is the team name lowercased with spaces stripped; verified against F1's CDN
        // for all eleven 2026 constructors.
        let expected: [String: String] = [
            "McLaren": "mclaren", "Ferrari": "ferrari", "Red Bull Racing": "redbullracing",
            "Mercedes": "mercedes", "Aston Martin": "astonmartin", "Alpine": "alpine",
            "Williams": "williams", "Racing Bulls": "racingbulls", "Haas F1 Team": "haasf1team",
            "Audi": "audi", "Cadillac": "cadillac",
        ]
        for (team, slug) in expected {
            let url = F1Constructor(name: team, colorHex: nil).logoURL(season: 2026)
            let string = try? XCTUnwrap(url?.absoluteString)
            XCTAssertEqual(string, "https://media.formula1.com/image/upload/c_fit,w_44/f_png/"
                           + "q_auto/common/f1/2026/\(slug)/2026\(slug)logo.webp",
                           "wrong URL for \(team)")
        }
        XCTAssertNil(F1Constructor(name: "", colorHex: nil).logoURL(season: 2026))
    }

    func testLiveReadoutCarriesTheConstructorLogo() throws {
        let live = try XCTUnwrap(FormulaOneAdapter.liveReadout(
            from: liveSnapshot(session: "Race", trackStatus: "1", lap: 5, total: 70), season: 2026))
        XCTAssertEqual(live.logo?.absoluteString.contains("/2026/mclaren/2026mclarenlogo.webp"), true)

        let scheduled = SportEvent(id: "x-Race", league: f1, state: .pre(startDate: nil),
                                   displayString: "", isFavorite: false, sortPriority: 0)
        XCTAssertNotNil(FormulaOneAdapter.applyLive(live, to: scheduled).leadLogo,
                        "the overlay carries the logo through to the menu bar")
    }

    // MARK: - SignalR envelope

    func testCompletionStateUnwrapsBothShapes() {
        let state = ["TrackStatus": ["Status": "1"]]
        XCTAssertNotNil(F1LiveTimingClient.completionState(["type": 3, "result": state]))
        XCTAssertNotNil(F1LiveTimingClient.completionState(["type": 3, "result": [state]]),
                        "F1 sometimes wraps the state in a single-element array")
        XCTAssertNil(F1LiveTimingClient.completionState(["type": 3]))
    }

    func testSubscribedTopicsExcludePaidTelemetry() {
        // CarData.z / Position.z are the only streams needing a paid F1 TV token — never ask.
        XCTAssertFalse(F1LiveTimingClient.topics.contains("CarData.z"))
        XCTAssertFalse(F1LiveTimingClient.topics.contains("Position.z"))
        XCTAssertTrue(F1LiveTimingClient.topics.contains("TrackStatus"))
        XCTAssertTrue(F1LiveTimingClient.topics.contains("SessionData"), "qualifying phase")
    }
}
