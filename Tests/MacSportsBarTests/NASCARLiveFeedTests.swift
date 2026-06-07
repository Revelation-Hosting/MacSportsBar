import XCTest
import SwiftUI
@testable import MacSportsBar

/// Tests for the NASCAR live-feed integration: the `RaceFlag` enum (mapped from the official
/// feed.nascar.com/swagger `flag_state`), the pure `RacingAdapter.liveReadout` mapping, and the
/// menu-bar `flagGlyph`. The green-flag fixture is a trimmed real capture from the 2026 Michigan
/// Cup race; caution/finish/not-active are exercised with targeted JSON.
final class NASCARLiveFeedTests: XCTestCase {

    /// Decode like `NASCARClient` does (snake_case → camelCase).
    private func feed(_ json: String) throws -> NASCARLiveFeed {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NASCARLiveFeed.self, from: Data(json.utf8))
    }

    // MARK: - RaceFlag enum (official spec: 1-Green 2-Yellow 3-Red 4-Finish 6-Stop 8-WarmUp 9-NotActive)

    func testFlagStateEnumMapping() {
        XCTAssertEqual(RaceFlag(flagState: 1), .green)
        XCTAssertEqual(RaceFlag(flagState: 2), .caution)
        XCTAssertEqual(RaceFlag(flagState: 3), .red)
        XCTAssertEqual(RaceFlag(flagState: 6), .red)        // 6-Stop also = stopped on track
        XCTAssertEqual(RaceFlag(flagState: 4), .checkered)  // 4-Finish, NOT 8 (the community myth)
        XCTAssertEqual(RaceFlag(flagState: 8), .warmup)     // 8 is Warm Up, not checkered
        XCTAssertNil(RaceFlag(flagState: 9))                // 9-Not Active → no flag
        XCTAssertNil(RaceFlag(flagState: nil))
        XCTAssertNil(RaceFlag(flagState: 7))                // unknown → no flag
    }

    // MARK: - liveReadout (pure mapping)

    /// Decode a bundled real-capture fixture the way `NASCARClient` does.
    private func fixture(_ name: String) throws -> NASCARLiveFeed {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "bundled fixture \(name) not found — check Package.swift resources")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NASCARLiveFeed.self, from: Data(contentsOf: url))
    }

    func testGreenFromRealFixture() throws {
        let live = try XCTUnwrap(RacingAdapter.liveReadout(from: fixture("nascar_live_green")))
        XCTAssertEqual(live.detail, "L36/200 · St1 · #45 Reddick")
        XCTAssertEqual(live.flag, .green)
        XCTAssertEqual(live.leaderName, "Reddick")
        XCTAssertFalse(live.finished)
    }

    func testCautionFromRealFixture() throws {
        // Trimmed real capture from the moment stage 1 ended (lap 47, yellow).
        let live = try XCTUnwrap(RacingAdapter.liveReadout(from: fixture("nascar_live_caution")))
        XCTAssertEqual(live.flag, .caution)
        XCTAssertEqual(live.detail, "L47/200 · St2 · #45 Reddick")
        XCTAssertFalse(live.finished)
    }

    func testFinishReadsAsWon() throws {
        let f = try feed("""
        {"series_id":1,"run_type":3,"flag_state":4,"laps_to_go":0,
         "vehicles":[{"running_position":1,"vehicle_number":"45","driver":{"full_name":"Tyler Reddick"}}]}
        """)
        let live = try XCTUnwrap(RacingAdapter.liveReadout(from: f))
        XCTAssertEqual(live.flag, .checkered)
        XCTAssertTrue(live.finished)
        XCTAssertEqual(live.detail, "#45 Reddick won")
    }

    func testWarmupReadsAsPace() throws {
        let f = try feed("""
        {"series_id":1,"run_type":3,"flag_state":8,
         "vehicles":[{"running_position":1,"vehicle_number":"45","driver":{"full_name":"Tyler Reddick"}}]}
        """)
        let live = try XCTUnwrap(RacingAdapter.liveReadout(from: f))
        XCTAssertEqual(live.flag, .warmup)
        XCTAssertEqual(live.detail, "Pace · #45 Reddick")
    }

    func testNotActiveYieldsNilSoESPNHandlesSchedule() throws {
        let f = try feed("{\"series_id\":1,\"run_type\":3,\"flag_state\":9}")
        XCTAssertNil(RacingAdapter.liveReadout(from: f), "flag 9 (Not Active) → let ESPN show the schedule")
    }

    func testNonCupRunIgnored() throws {
        // Xfinity (series 2) on track shouldn't hijack the Cup race slot.
        let f = try feed("{\"series_id\":2,\"run_type\":3,\"flag_state\":1,\"lap_number\":10}")
        XCTAssertNil(RacingAdapter.liveReadout(from: f))
        // Practice (run_type 1) ignored too.
        let practice = try feed("{\"series_id\":1,\"run_type\":1,\"flag_state\":1}")
        XCTAssertNil(RacingAdapter.liveReadout(from: practice))
    }

    // MARK: - Menu-bar flag glyph

    func testFlagGlyphSymbolsAndColors() {
        XCTAssertEqual(AppModel.flagGlyph(.green).symbol, "flag.fill")
        XCTAssertNotNil(AppModel.flagGlyph(.green).color)
        XCTAssertNotNil(AppModel.flagGlyph(.caution).color)
        XCTAssertNotNil(AppModel.flagGlyph(.red).color)
        XCTAssertEqual(AppModel.flagGlyph(.checkered).symbol, "flag.checkered")
        XCTAssertNil(AppModel.flagGlyph(.checkered).color, "checkered tints with the menu bar")
        XCTAssertNil(AppModel.flagGlyph(.warmup).color, "pace laps have no distinct hue")
    }
}
