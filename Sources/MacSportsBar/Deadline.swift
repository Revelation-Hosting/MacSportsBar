import Foundation

/// Thrown by `withDeadline` when the operation outlives its deadline.
struct DeadlineExceeded: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "no answer within \(Int(seconds))s" }
}

/// Await `operation`, but give up after `seconds` and cancel it.
///
/// This returns on time even when the operation ignores cancellation, which a task group can't
/// promise: a group waits for every child before it returns, and a child that never returns is
/// the whole problem. The poll loop awaits each league in turn, so one request that never
/// completes (a connection stranded when the Mac slept mid-fetch) froze every sport for days
/// until Refresh Now. Here the abandoned operation is cancelled and left to finish on its own.
///
/// The deadline runs on the continuous clock, which keeps counting while the Mac sleeps, so an
/// operation caught by sleep is abandoned as soon as it wakes.
func withDeadline<T: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()  // a caller that's already given up shouldn't start a request
    let race = FirstFinisher<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds), clock: .continuous)
                race.finish(.failure(DeadlineExceeded(seconds: seconds)))
            }
            race.arm(continuation, cancelling: [work, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The one-shot hand-off behind `withDeadline`. The operation, the timer and cancellation race to
/// finish; the first result resumes the caller and cancels the other two tasks, and later results
/// are dropped. A result can land before the continuation is armed (the operation was instant,
/// or the caller was already cancelled), so it's held until then.
private final class FirstFinisher<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var result: Result<T, Error>?

    func arm(_ continuation: CheckedContinuation<T, Error>, cancelling tasks: [Task<Void, Never>]) {
        lock.lock()
        guard let result else {
            self.continuation = continuation
            self.tasks = tasks
            lock.unlock()
            return
        }
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation.resume(with: result)
    }

    func finish(_ outcome: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let continuation = self.continuation
        let tasks = self.tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: outcome)
    }
}
