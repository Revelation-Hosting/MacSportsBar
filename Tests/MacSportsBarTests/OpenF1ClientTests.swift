import XCTest
@testable import MacSportsBar

/// Tests for the OpenF1 pieces: the constructor map (the one thing we take from OpenF1, since ESPN
/// has no F1 team data) and the free-tier session picker that keeps us out of OpenF1's paid live
/// window. Plus the hex→Color parse used to tint the menu-bar glyph.
final class OpenF1ClientTests: XCTestCase {

    // MARK: - Constructor map

    func testConstructorMapFromRealDriversFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "openf1_drivers", withExtension: "json", subdirectory: "Fixtures"))
        let drivers = try JSONDecoder().decode(
            [OpenF1Client.Driver].self, from: Data(contentsOf: url))
        let map = OpenF1Client.constructorMap(from: drivers)

        XCTAssertEqual(drivers.count, 22, "a full 2026 grid")
        XCTAssertEqual(map["norris"]?.name, "McLaren")
        XCTAssertEqual(map["norris"]?.colorHex, "F47600")
        XCTAssertEqual(map["verstappen"]?.name, "Red Bull Racing")
        // 2026's new constructors are present — proof the map isn't a stale hardcode.
        XCTAssertTrue(map.values.contains { $0.name == "Audi" })
        XCTAssertTrue(map.values.contains { $0.name == "Cadillac" })
    }

    func testConstructorMapSkipsUnusableEntries() {
        let drivers = [
            OpenF1Client.Driver(lastName: "Norris", nameAcronym: "NOR",
                                teamName: "McLaren", teamColour: "F47600"),
            OpenF1Client.Driver(lastName: nil, nameAcronym: "XXX",
                                teamName: "Ghost", teamColour: nil),
            OpenF1Client.Driver(lastName: "Nobody", nameAcronym: "NOB",
                                teamName: nil, teamColour: nil),
        ]
        let map = OpenF1Client.constructorMap(from: drivers)
        XCTAssertEqual(map.count, 1)
        XCTAssertNotNil(map["norris"], "keys are lowercased surnames, to join against ESPN names")
    }

    // MARK: - Free-tier session selection

    func testPicksNewestSessionOutsideThePaidLiveWindow() {
        // OpenF1 bills anything up to 30 min after a session ends as live/paid, so a session that
        // ended 10 minutes ago must NOT be chosen even though it's the newest.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func session(_ key: Int, endedMinutesAgo: Double) -> OpenF1Client.Session {
            let end = now.addingTimeInterval(-endedMinutesAgo * 60)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            return OpenF1Client.Session(sessionKey: key, dateEnd: iso.string(from: end))
        }
        let sessions = [session(1, endedMinutesAgo: 600),
                        session(2, endedMinutesAgo: 90),
                        session(3, endedMinutesAgo: 10)]   // still inside the paid window
        XCTAssertEqual(OpenF1Client.newestHistoricalSessionKey(in: sessions, now: now), 2)
    }

    func testNoFinishedSessionYieldsNil() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let upcoming = OpenF1Client.Session(
            sessionKey: 9, dateEnd: iso.string(from: now.addingTimeInterval(3600)))
        XCTAssertNil(OpenF1Client.newestHistoricalSessionKey(in: [upcoming], now: now))
        XCTAssertNil(OpenF1Client.newestHistoricalSessionKey(in: [], now: now))
    }

    func testParsesBothTimestampPrecisions() {
        // OpenF1 mixes whole-second and fractional-second stamps across endpoints.
        XCTAssertNotNil(OpenF1Client.parseDate("2026-07-24T16:00:00+00:00"))
        XCTAssertNotNil(OpenF1Client.parseDate("2026-07-18T14:56:54.534000+00:00"))
        XCTAssertNil(OpenF1Client.parseDate("not a date"))
    }

    // MARK: - Constructor colour → menu-bar glyph

    func testHexColorParsing() {
        XCTAssertNotNil(AppModel.color(hex: "F47600"), "McLaren papaya")
        XCTAssertNotNil(AppModel.color(hex: "#00D7B6"), "leading # tolerated")
        XCTAssertNil(AppModel.color(hex: "F476"), "wrong length")
        XCTAssertNil(AppModel.color(hex: "ZZZZZZ"), "not hex")
        XCTAssertNil(AppModel.color(hex: ""))
    }
}
