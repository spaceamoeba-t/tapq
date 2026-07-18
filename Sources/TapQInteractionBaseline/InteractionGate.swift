import Foundation
import TapQContracts

/// Serializes async work on the MainActor in FIFO order. The hands-free stack has one
/// pair of ears and one voice: overlapping broker requests (Claude Code fires parallel
/// tool calls in a single response) must take turns at the speech/gesture hardware
/// instead of clobbering the arbiters' single listen window.
///
/// Not reentrant: calling `run` from inside a running body deadlocks.
@MainActor public final class InteractionGate {
    private var tail: Task<Void, Never>?

    public init() {}

    /// Runs `body` after every previously enqueued body has finished. Returns its value.
    public func run<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await body()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}
