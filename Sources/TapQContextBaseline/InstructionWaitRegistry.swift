import Foundation
import TapQContracts

/// Why a held turn boundary was let go.
public enum InstructionWaitOutcome: Sendable, Equatable {
    /// An instruction was queued for the session. The caller drains the queue; the wait
    /// itself carries no text, so there is exactly one path an instruction reaches an agent
    /// by and this is not a second one.
    case instructionQueued
    /// The broker's wait budget expired. The Stop proceeds and the session idles normally.
    case timedOut
    /// The hold was released without an instruction — the wearer ended the voice session,
    /// or the runtime is shutting down. Indistinguishable from a timeout to the shim, and
    /// deliberately so: both mean "nothing is coming, carry on".
    case released
}

/// The turn boundaries this runtime is holding open, and the thing that lets them go.
///
/// A voice session inverts the instruction channel's timing. Delivery has always happened
/// *at* a boundary the agent produced, which means an instruction dictated to an idle agent
/// waits for someone to type; a held boundary is the same delivery with the waiting moved
/// to the other side of the wire, where it costs a parked hook instead of a lost sentence.
///
/// The registry is the whole of that inversion, and it is deliberately small enough to hold
/// in one's head: a waiter is a continuation and a session id, and there are exactly three
/// ways for one to be resumed — an instruction arrives, the budget expires, or someone lets
/// it go. Nothing here reads or writes an instruction. It only says *when*.
///
/// `@MainActor`, like the mailbox it lives beside, so the enqueue that wakes a waiter and
/// the drain that follows it happen in the same actor turn and cannot interleave.
@MainActor public final class InstructionWaitRegistry {
    /// A waiting boundary, in the two terms anything here may know about it.
    private struct Waiter {
        let sessionID: String
        let continuation: CheckedContinuation<InstructionWaitOutcome, Never>
    }

    private var waiters: [UInt64: Waiter] = [:]
    private var nextID: UInt64 = 0
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let diagnostics: TapQDiagnosticEmitter

    /// Fired whenever the number of held boundaries changes, so a host can start listening
    /// when the first one arrives and stop when the last one leaves.
    ///
    /// A callback rather than a poll because the thing it drives is a microphone: a loop
    /// that polled would either open windows nobody is waiting behind or leave a wearer
    /// talking to a runtime that had not noticed yet.
    public var onWaitingChanged: (@MainActor (Int) -> Void)?

    /// - Parameters:
    ///   - sleep: the wait budget's timer, injected so tests can expire a ten-minute
    ///     budget without waiting ten minutes.
    public init(
        sleep: @escaping @MainActor (TimeInterval) async -> Void = {
            try? await Task.sleep(for: .seconds($0))
        },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.sleep = sleep
        self.diagnostics = TapQDiagnosticEmitter(category: "InstructionWait", sink: diagnosticSink)
    }

    // MARK: - Waiting

    /// Holds `session`'s boundary open until something happens to it, and says what.
    ///
    /// The timeout task is started before the continuation is stored, and both run on this
    /// actor, so the entry always exists by the time the budget can expire — a wait can
    /// never be resumed before it is registered, and a resumed wait is removed before it
    /// returns, so no continuation is resumed twice.
    public func wait(session: String, timeout: TimeInterval) async -> InstructionWaitOutcome {
        nextID &+= 1
        let id = nextID
        let budget = Task { @MainActor [weak self, sleep = self.sleep] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            self?.resume(id, with: .timedOut)
        }
        diagnostics.record("wait.began", fields: [
            "session": session, "budget": "\(Int(timeout))",
        ])
        let outcome = await withCheckedContinuation { continuation in
            waiters[id] = Waiter(sessionID: session, continuation: continuation)
            onWaitingChanged?(waiters.count)
        }
        budget.cancel()
        diagnostics.record("wait.ended", fields: [
            "session": session, "outcome": "\(outcome)",
        ])
        return outcome
    }

    // MARK: - Releasing

    /// Wakes every boundary held for `session`, because something was queued for it.
    ///
    /// Called from the mailbox's enqueue observer, so every way an instruction can arrive —
    /// a dictation, `tapq instruct`, a future device SDK — releases the hold without any of
    /// them knowing this type exists.
    public func noteInstructionQueued(session: String) {
        resumeAll(matching: { $0.sessionID == session }, with: .instructionQueued)
    }

    /// Lets go of every boundary held for `session` with no instruction: the wearer said
    /// they were done listening.
    public func release(session: String) {
        resumeAll(matching: { $0.sessionID == session }, with: .released)
    }

    /// Lets go of every held boundary. The runtime's shutdown path calls it, which is what
    /// keeps a killed runtime from leaving a hook parked until its socket times out.
    public func releaseAll() {
        resumeAll(matching: { _ in true }, with: .released)
    }

    // MARK: - Reading

    /// How many boundaries are held right now.
    public var waitingCount: Int { waiters.count }

    /// Whether any boundary is held. The listening loop's condition.
    public var isWaiting: Bool { !waiters.isEmpty }

    /// The sessions being held, in no defined order. A host composing a dictation target
    /// reads this rather than guessing from conversation memory: the session whose boundary
    /// is open is the one the wearer is talking into.
    public var waitingSessions: [String] {
        Array(Set(waiters.values.map(\.sessionID)))
    }

    // MARK: - Internals

    private func resume(_ id: UInt64, with outcome: InstructionWaitOutcome) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: outcome)
        onWaitingChanged?(waiters.count)
    }

    private func resumeAll(
        matching predicate: (Waiter) -> Bool,
        with outcome: InstructionWaitOutcome
    ) {
        let matched = waiters.filter { predicate($0.value) }
        guard !matched.isEmpty else { return }
        for (id, waiter) in matched {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: outcome)
        }
        diagnostics.record("wait.released", fields: [
            "count": "\(matched.count)", "outcome": "\(outcome)",
        ])
        onWaitingChanged?(waiters.count)
    }
}
