import Foundation

/// How a piece of work ended relative to its deadline.
enum ReasonerDeadlineResult<Value: Sendable>: Sendable {
    case completed(Value)
    /// The budget ran out. The work may still be running; its result is discarded.
    case timedOut
    /// The caller was cancelled before either of the above happened.
    case cancelled
}

/// Runs model work under a hard wall-clock budget.
///
/// This exists because the obvious shape does not actually bound anything. Two children
/// of a task group with `cancelAll()` on the loser — the idiom the question classifiers
/// use — returns the *timeout value* on time, but a task group waits for every child
/// before it returns, so a backend that is slow to observe cancellation keeps the caller
/// suspended long past the deadline. Measured with a deliberately uncancellable child,
/// a 0.2-second budget over 3 seconds of work takes 3 seconds to return.
///
/// A stage-2 reasoner runs while the user is holding a gesture, so the deadline has to
/// hold whether or not the backend cooperates. The work therefore runs unstructured and
/// reports through a gate that resumes exactly once; whichever outcome arrives first
/// wins, and the losers find the gate settled and do nothing.
///
/// Lives here, outside the `canImport(FoundationModels)` guard, on purpose: CI does not
/// compile the on-device adapter at all, so a deadline implemented inside it would be
/// neither built nor tested on the machine that gates merges.
enum ReasonerDeadline {
    static func run<Value: Sendable>(
        seconds: Double,
        work: @escaping @Sendable () async -> Value
    ) async -> ReasonerDeadlineResult<Value> {
        let gate = OutcomeGate<Value>()
        let worker = Task { gate.settle(.completed(await work())) }
        let budget = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if gate.settle(.timedOut) { worker.cancel() }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation)
            }
        } onCancel: {
            if gate.settle(.cancelled) { worker.cancel() }
            budget.cancel()
        }
    }

    /// A continuation resumed exactly once, by whichever racer gets there first.
    ///
    /// `settle(_:)` can run before `arm(_:)` — a zero-second budget fires while
    /// `withCheckedContinuation` is still handing the continuation over — so the winning
    /// outcome is held until there is something to resume it with. Resuming a
    /// continuation twice traps, so the winner is chosen under the lock while the resume
    /// itself happens outside it.
    private final class OutcomeGate<Value: Sendable>: @unchecked Sendable {
        typealias Result = ReasonerDeadlineResult<Value>

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        private var result: Result?

        func arm(_ continuation: CheckedContinuation<Result, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        /// Reports whether this outcome won, so only the winner pays for cancelling the
        /// work that lost.
        @discardableResult
        func settle(_ result: Result) -> Bool {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return false
            }
            self.result = result
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: result)
            return true
        }
    }
}
