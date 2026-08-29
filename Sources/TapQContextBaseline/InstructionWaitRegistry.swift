import Foundation
import TapQContracts

/// Why a held turn boundary was let go.
public enum InstructionWaitOutcome: Sendable, Equatable {
    /// An instruction was queued for the session. The caller drains the queue; the wait
    /// itself carries no text, so there is exactly one path an instruction reaches an agent
    /// by and this is not a second one.
    case instructionQueued
    /// This poll's bound elapsed and the boundary is still held. The caller tells the shim
    /// to park again; nothing about the session has changed and nothing is announced.
    ///
    /// Only a lease-bearing wait can end this way, because only a caller that presented a
    /// lease has said it will come back.
    case renew
    /// A one-shot wait's budget expired. The Stop proceeds and the session idles normally.
    /// Reachable only without a lease — a leased hold is not ended by time.
    case timedOut
    /// The hold was released without an instruction — the wearer ended the voice session,
    /// the voice pipeline broke, or the runtime is shutting down. Indistinguishable from a
    /// timeout to the shim, and deliberately so: both mean "nothing is coming, carry on".
    case released
}

/// The turn boundaries this runtime is holding open, and the thing that lets them go.
///
/// A voice session inverts the instruction channel's timing. Delivery has always happened
/// *at* a boundary the agent produced, which means an instruction dictated to an idle agent
/// waits for someone to type; a held boundary is the same delivery with the waiting moved
/// to the other side of the wire, where it costs a parked hook instead of a lost sentence.
///
/// **A held boundary is not ended by time** (ratified 2026-08-28). It ends when an
/// instruction arrives for it, when someone lets it go — a gesture, a tap, a broken voice
/// pipeline, shutdown — or when the hook holding it stops coming back. Nothing here counts
/// minutes toward an ending.
///
/// What time still does is *renew*. A waiter parks for one poll's bound and is answered
/// `renew`; its shim re-polls; the boundary is unchanged throughout. Between those polls
/// there is no continuation registered, so a **lease** stands in for one: the registry
/// keeps the boundary counted, named, and listened-to across the gap, and only lets it go
/// when no poll has come back for `leaseGrace`. That is the whole reason this type is
/// bigger than it was — a waiter is still a continuation and a session id, and a lease is
/// what makes a *sequence* of waiters one held boundary.
///
/// A lease that is released is remembered as released. Without that, a `releaseAll` landing
/// in the microseconds between two polls would be undone by the next one, and "end voice
/// session" would end nothing.
///
/// `@MainActor`, like the mailbox it lives beside, so the enqueue that wakes a waiter and
/// the drain that follows it happen in the same actor turn and cannot interleave.
@MainActor public final class InstructionWaitRegistry {
    /// A waiting boundary, in the terms anything here may know about it.
    private struct Waiter {
        let sessionID: String
        /// The held boundary this poll belongs to, or nil for a one-shot wait.
        let leaseID: String?
        let continuation: CheckedContinuation<InstructionWaitOutcome, Never>
    }

    /// One held boundary, across however many polls hold it.
    private struct Lease {
        let sessionID: String
        /// Polls currently parked on this boundary. Normally 1; briefly 0 between them.
        var polls: Int
        /// How many times this boundary has been renewed, for the diagnostic below.
        var renewals: Int
        /// Runs while `polls` is 0. If it finishes, the hook is gone.
        var grace: Task<Void, Never>?
    }

    private var waiters: [UInt64: Waiter] = [:]
    private var leases: [String: Lease] = [:]
    /// Leases that were let go. A poll arriving for one of these is answered immediately
    /// rather than re-parked, so a release cannot be undone by a re-poll that was already
    /// in flight when it landed.
    ///
    /// Bounded, and oldest-first: the only thing it has to outlive is a poll in flight, and
    /// a run long enough to overflow it has long since forgotten the sessions involved.
    private var releasedLeases: Set<String> = []
    private var releasedLeaseOrder: [String] = []
    private static let releasedLeaseMemory = 512
    private var nextID: UInt64 = 0
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let diagnostics: TapQDiagnosticEmitter

    /// How long a lease survives with no poll parked on it. Read from the shared contract
    /// so the shim's poll bound and this grace stay in the same chain.
    private var graceInterval: TimeInterval { VoiceSessionBudget.leaseGrace }

    /// Renewals are the heartbeat of a healthy voice session and there is one a minute, so
    /// only every tenth is worth an info line. The rest are debug.
    private static let renewalLogInterval = 10

    /// Fired whenever the number of held boundaries changes, so a host can start listening
    /// when the first one arrives and stop when the last one leaves.
    ///
    /// A callback rather than a poll because the thing it drives is a microphone: a loop
    /// that polled would either open windows nobody is waiting behind or leave a wearer
    /// talking to a runtime that had not noticed yet. A renewal is deliberately *not* a
    /// change — the lease is what keeps this quiet across the gap between polls, so the
    /// microphone never closes and reopens once a minute.
    public var onWaitingChanged: (@MainActor (Int) -> Void)?

    /// - Parameters:
    ///   - sleep: the poll bound's and the lease grace's timer, injected so tests can expire
    ///     either without waiting for it. The duration is passed through, so a test that
    ///     needs to expire one and not the other can branch on it.
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
    /// actor, so the entry always exists by the time the bound can elapse — a wait can
    /// never be resumed before it is registered, and a resumed wait is removed before it
    /// returns, so no continuation is resumed twice.
    ///
    /// - Parameters:
    ///   - timeout: this poll's bound. With a `lease` it is a renewal interval; without
    ///     one it is the older one-shot budget and expiring it ends the wait.
    ///   - lease: the boundary this poll belongs to, stable across the polls that hold it.
    ///     `nil` — the default, and every caller that predates leases — is one-shot.
    public func wait(
        session: String,
        timeout: TimeInterval,
        lease: String? = nil
    ) async -> InstructionWaitOutcome {
        if let lease {
            // A boundary that was let go stays let go. Answering rather than parking is
            // what keeps a release from being undone by the poll that was already on its
            // way when the wearer ended the session.
            guard !releasedLeases.contains(lease) else {
                diagnostics.record("wait.released", fields: [
                    "session": session, "reason": "lease_already_released",
                ])
                return .released
            }
            beginLease(lease, session: session)
        } else {
            diagnostics.record("wait.began", fields: [
                "session": session, "budget": "\(Int(timeout))",
            ])
        }

        nextID &+= 1
        let id = nextID
        let expiry: InstructionWaitOutcome = lease == nil ? .timedOut : .renew
        let budget = Task { @MainActor [weak self, sleep = self.sleep] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            self?.resume(id, with: expiry)
        }
        let outcome = await withCheckedContinuation { continuation in
            // A leased poll parking again is not a new boundary, and `beginLease` already
            // reported the one it belongs to — so this only fires for a one-shot wait.
            reportingChange {
                waiters[id] = Waiter(
                    sessionID: session, leaseID: lease, continuation: continuation
                )
            }
        }
        budget.cancel()
        if let lease {
            endLease(lease, outcome: outcome)
        } else {
            diagnostics.record("wait.ended", fields: [
                "session": session, "outcome": "\(outcome)",
            ])
        }
        return outcome
    }

    /// Whether `lease` names a boundary already being held — a re-poll of one this registry
    /// has seen rather than a new one.
    ///
    /// The host reads it to tell an announcement from a renewal: a new boundary says
    /// "Listening.", a renewal says nothing at all.
    public func isHeld(lease: String) -> Bool { leases[lease] != nil }

    // MARK: - Releasing

    /// Wakes every boundary held for `session`, because something was queued for it.
    ///
    /// Called from the mailbox's enqueue observer, so every way an instruction can arrive —
    /// a dictation, `tapq instruct`, a future device SDK — releases the hold without any of
    /// them knowing this type exists.
    ///
    /// An instruction that lands between two polls wakes nothing, and needs to wake nothing:
    /// it stays in the mailbox and the next poll is answered from it before it parks.
    public func noteInstructionQueued(session: String) {
        resumeAll(matching: { $0.sessionID == session }, with: .instructionQueued)
    }

    /// Lets go of one boundary by name, because it was answered without ever parking: an
    /// instruction was already queued when its poll arrived, so the host delivered it
    /// straight away and this wait never suspended.
    ///
    /// Without it the lease would sit out its whole grace after the agent had already gone
    /// back to work, and TapQ would keep opening listening windows at a boundary that was
    /// answered. Marked released for the same reason every other ending is: the shim is not
    /// coming back for this one.
    public func release(lease: String) {
        endLeases(matching: { $0.key == lease }, reason: "delivered")
    }

    /// Lets go of every boundary held for `session` with no instruction: the wearer ended
    /// the voice session.
    public func release(session: String) {
        endLeases(matching: { $0.value.sessionID == session }, reason: "session_released")
        resumeAll(matching: { $0.sessionID == session }, with: .released)
    }

    /// Lets go of every held boundary. The runtime's shutdown path calls it, and so does
    /// the voice-break latch, which is what keeps a dead microphone or a killed runtime
    /// from leaving a hook parked against a session nobody can hear.
    public func releaseAll() {
        endLeases(matching: { _ in true }, reason: "released_all")
        resumeAll(matching: { _ in true }, with: .released)
    }

    // MARK: - Reading

    /// How many boundaries are held right now. A leased boundary counts once whether or not
    /// one of its polls happens to be parked at this instant.
    public var waitingCount: Int {
        leases.count + waiters.values.filter { $0.leaseID == nil }.count
    }

    /// Whether any boundary is held. The listening loop's condition.
    public var isWaiting: Bool { waitingCount > 0 }

    /// The sessions being held, in no defined order. A host composing a dictation target
    /// reads this rather than guessing from conversation memory: the session whose boundary
    /// is open is the one the wearer is talking into.
    public var waitingSessions: [String] {
        Array(Set(waiters.values.map(\.sessionID) + leases.values.map(\.sessionID)))
    }

    // MARK: - Leases

    private func beginLease(_ lease: String, session: String) {
        if var existing = leases[lease] {
            existing.grace?.cancel()
            existing.grace = nil
            existing.polls += 1
            leases[lease] = existing
            return
        }
        reportingChange {
            leases[lease] = Lease(sessionID: session, polls: 1, renewals: 0, grace: nil)
            diagnostics.record("wait.began", fields: ["session": session, "lease": lease])
        }
    }

    private func endLease(_ lease: String, outcome: InstructionWaitOutcome) {
        // Already gone: a release tore the lease down while this poll was parked, and the
        // teardown has already reported it.
        guard var state = leases[lease] else { return }
        state.polls = max(0, state.polls - 1)

        guard outcome == .renew else {
            // Anything that is not a renewal is an ending, and an ended boundary is
            // remembered as ended: the shim is not coming back for this one, and a poll
            // that somehow still arrives for it must be answered rather than re-park.
            reportingChange {
                state.grace?.cancel()
                leases.removeValue(forKey: lease)
                rememberReleased(lease)
                diagnostics.record("wait.ended", fields: [
                    "session": state.sessionID, "lease": lease, "outcome": "\(outcome)",
                    "renewals": "\(state.renewals)",
                ])
            }
            return
        }

        state.renewals += 1
        let renewals = state.renewals
        // A renewal a minute for an afternoon is a lot of lines. Every tenth is enough to
        // show the session is alive; the rest are there when someone is debugging one.
        diagnostics.record(
            "wait.renewed",
            level: renewals % Self.renewalLogInterval == 0 ? .info : .debug,
            fields: ["session": state.sessionID, "lease": lease, "renewals": "\(renewals)"]
        )
        if state.polls == 0 {
            state.grace = Task { @MainActor [weak self, sleep = self.sleep, grace = graceInterval] in
                await sleep(grace)
                guard !Task.isCancelled else { return }
                self?.expireLease(lease)
            }
        }
        leases[lease] = state
        // The count is deliberately unchanged: the boundary is still held, and saying
        // otherwise would close the microphone once a minute.
    }

    /// The hook stopped coming back — killed at the agent's own ceiling, or its terminal
    /// closed. Nothing is parked to resume; the boundary simply stops being held.
    private func expireLease(_ lease: String) {
        guard let state = leases[lease], state.polls == 0 else { return }
        reportingChange {
            state.grace?.cancel()
            leases.removeValue(forKey: lease)
            rememberReleased(lease)
            diagnostics.record("wait.released", fields: [
                "session": state.sessionID, "lease": lease, "reason": "lease_expired",
                "renewals": "\(state.renewals)",
            ])
        }
    }

    private func endLeases(
        matching predicate: ((key: String, value: Lease)) -> Bool,
        reason: String
    ) {
        let matched = leases.filter { predicate((key: $0.key, value: $0.value)) }
        guard !matched.isEmpty else { return }
        reportingChange {
            for (lease, state) in matched {
                state.grace?.cancel()
                leases.removeValue(forKey: lease)
                rememberReleased(lease)
            }
            diagnostics.record("wait.released", fields: [
                "count": "\(matched.count)", "reason": reason,
            ])
        }
    }

    private func rememberReleased(_ lease: String) {
        guard releasedLeases.insert(lease).inserted else { return }
        releasedLeaseOrder.append(lease)
        while releasedLeaseOrder.count > Self.releasedLeaseMemory {
            releasedLeases.remove(releasedLeaseOrder.removeFirst())
        }
    }

    // MARK: - Internals

    /// Runs `body` and tells the host only if the number of held boundaries actually moved.
    ///
    /// Every mutation here goes through it for one reason: a held boundary passes through
    /// several of them in a row — a lease torn down, then its waiter resumed, then that
    /// wait's epilogue — and a host that re-derived its microphone state from each would
    /// stop and start listening inside a single release.
    private func reportingChange(_ body: () -> Void) {
        let before = waitingCount
        body()
        let after = waitingCount
        if before != after { onWaitingChanged?(after) }
    }

    private func resume(_ id: UInt64, with outcome: InstructionWaitOutcome) {
        reportingChange {
            guard let waiter = waiters.removeValue(forKey: id) else { return }
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func resumeAll(
        matching predicate: (Waiter) -> Bool,
        with outcome: InstructionWaitOutcome
    ) {
        let matched = waiters.filter { predicate($0.value) }
        guard !matched.isEmpty else { return }
        reportingChange {
            for (id, waiter) in matched {
                waiters.removeValue(forKey: id)
                waiter.continuation.resume(returning: outcome)
            }
            diagnostics.record("wait.released", fields: [
                "count": "\(matched.count)", "outcome": "\(outcome)",
            ])
        }
    }
}
