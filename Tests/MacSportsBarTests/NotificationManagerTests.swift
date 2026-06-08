import XCTest
@testable import MacSportsBar

/// Tests for the pure boundary classifier that decides when a notification fires.
final class NotificationManagerTests: XCTestCase {
    typealias Snapshot = NotificationManager.Snapshot

    func testFirstSightingNeverNotifies() {
        XCTAssertEqual(NotificationManager.boundary(from: nil, to: Snapshot(period: 2, isFinal: false)), .none)
        XCTAssertEqual(NotificationManager.boundary(from: nil, to: Snapshot(period: nil, isFinal: true)), .none)
    }

    func testPeriodAdvanceDetected() {
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: 1, isFinal: false),
                                         to: Snapshot(period: 2, isFinal: false)),
            .periodAdvanced)
    }

    func testSamePeriodIsNoBoundary() {
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: 2, isFinal: false),
                                         to: Snapshot(period: 2, isFinal: false)),
            .none)
    }

    func testGoingFinalDetected() {
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: 4, isFinal: false),
                                         to: Snapshot(period: 4, isFinal: true)),
            .final)
    }

    func testFinalTakesPrecedenceOverPeriodAdvance() {
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: 3, isFinal: false),
                                         to: Snapshot(period: 4, isFinal: true)),
            .final)
    }

    func testAlreadyFinalDoesNotRepeat() {
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: 4, isFinal: true),
                                         to: Snapshot(period: 4, isFinal: true)),
            .none)
    }

    func testNilPeriodsHaveNoPeriodBoundary() {
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: nil, isFinal: false),
                                         to: Snapshot(period: nil, isFinal: false)),
            .none)
    }

    func testGameStartingDetected() {
        // pre (not live) → live = the game started.
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: nil, isFinal: false, isLive: false),
                                         to: Snapshot(period: 1, isFinal: false, isLive: true)),
            .started)
    }

    func testAlreadyLiveDoesNotRepeatStart() {
        // Launching mid-game (first sighting) is quiet, and a live game staying live doesn't restart.
        XCTAssertEqual(
            NotificationManager.boundary(from: nil, to: Snapshot(period: 2, isFinal: false, isLive: true)),
            .none)
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: 1, isFinal: false, isLive: true),
                                         to: Snapshot(period: 1, isFinal: false, isLive: true)),
            .none)
    }

    func testFinalTakesPrecedenceOverStart() {
        // A pre game seen as final next poll (postponed→over edge) is a final, not a start.
        XCTAssertEqual(
            NotificationManager.boundary(from: Snapshot(period: nil, isFinal: false, isLive: false),
                                         to: Snapshot(period: nil, isFinal: true, isLive: false)),
            .final)
    }

    // MARK: - Per-kind preferences (each notification type toggles independently)

    func testShouldNotifyRespectsEachToggle() {
        // Default-ish: start + final on, period (the noisy one) off.
        let prefs = NotificationManager.Preferences(start: true, period: false, final: true)
        XCTAssertTrue(NotificationManager.shouldNotify(.started, prefs: prefs))
        XCTAssertFalse(NotificationManager.shouldNotify(.periodAdvanced, prefs: prefs))
        XCTAssertTrue(NotificationManager.shouldNotify(.final, prefs: prefs))
        XCTAssertFalse(NotificationManager.shouldNotify(.none, prefs: prefs))
    }

    func testShouldNotifyAllOffSilencesEverything() {
        let off = NotificationManager.Preferences(start: false, period: false, final: false)
        for b in [NotificationManager.Boundary.started, .periodAdvanced, .final, .none] {
            XCTAssertFalse(NotificationManager.shouldNotify(b, prefs: off))
        }
    }

    func testShouldNotifyPeriodOnlyWhenEnabled() {
        let periodOn = NotificationManager.Preferences(start: false, period: true, final: false)
        XCTAssertTrue(NotificationManager.shouldNotify(.periodAdvanced, prefs: periodOn))
        XCTAssertFalse(NotificationManager.shouldNotify(.started, prefs: periodOn))
    }
}
