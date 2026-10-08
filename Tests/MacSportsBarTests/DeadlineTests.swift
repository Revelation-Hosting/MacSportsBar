import XCTest
@testable import MacSportsBar

/// Tests for `withDeadline`, the bound on every league's fetch. The case that matters is an
/// operation that ignores cancellation: that is what a stranded network read looks like, and it
/// must not hold the caller past the deadline.
final class DeadlineTests: XCTestCase {

    private struct Boom: Error {}

    func testReturnsTheOperationsValue() async throws {
        let value = try await withDeadline(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testPropagatesTheOperationsError() async {
        do {
            _ = try await withDeadline(seconds: 5) { () async throws -> Int in throw Boom() }
            XCTFail("expected the operation's error")
        } catch {
            XCTAssertTrue(error is Boom, "got \(error)")
        }
    }

    func testGivesUpOnAnOperationThatIgnoresCancellation() async {
        let started = ContinuousClock.now
        do {
            _ = try await withDeadline(seconds: 0.2) { await Self.hangIgnoringCancellation(for: 5) }
            XCTFail("expected the deadline to fire")
        } catch {
            XCTAssertTrue(error is DeadlineExceeded, "got \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testCallerCancellationReturnsPromptly() async {
        let started = ContinuousClock.now
        let caller = Task {
            try await withDeadline(seconds: 30) { await Self.hangIgnoringCancellation(for: 5) }
        }
        try? await Task.sleep(for: .milliseconds(100))
        caller.cancel()
        let result = await caller.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testCancelsTheOperationItAbandons() async throws {
        let cancelled = Flag()
        do {
            _ = try await withDeadline(seconds: 0.1) { () async throws -> Int in
                do { try await Task.sleep(for: .seconds(5)) } catch { cancelled.set() }
                return 0
            }
            XCTFail("expected the deadline to fire")
        } catch {}
        // The operation hears about it just after the caller gets control back.
        for _ in 0..<50 where !cancelled.value { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(cancelled.value, "an abandoned fetch must be cancelled, not left running")
    }

    func testAlreadyCancelledCallerNeverStartsTheOperation() async {
        let started = Flag()
        let caller = Task {
            try? await Task.sleep(for: .seconds(5))  // ends at once when cancelled
            return try await withDeadline(seconds: 5) { started.set(); return 1 }
        }
        caller.cancel()
        let result = await caller.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        XCTAssertFalse(started.value)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
        func set() { lock.lock(); isSet = true; lock.unlock() }
    }

    /// Finish after `seconds` no matter what — the shape of a socket read that cancellation
    /// can't reach.
    private static func hangIgnoringCancellation(for seconds: Double) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume(returning: 0) }
        }
    }
}
