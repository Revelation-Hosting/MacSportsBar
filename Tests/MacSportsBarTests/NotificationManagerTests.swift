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
}
