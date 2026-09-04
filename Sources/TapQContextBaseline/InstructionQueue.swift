import Foundation
import TapQContracts

/// One instruction, waiting for the agent's next turn boundary, tagged with whose
/// sentence it is.
///
/// The text is the wearer's own words, whole. Whitespace is collapsed — a newline in a
/// stop-hook reply would break the delivery template, and a dictation transcript has no
/// meaningful line structure to preserve — and *nothing else* is done to it. Like
/// ``SessionContextEvent``, the type has nowhere to put a `toolInput`, a `cwd`, or a
/// `permissionMode`: an instruction is something the wearer said out loud and TapQ read
/// back to them, and nothing else ever reaches it.
///
/// ## Why there is no length cap here any more
///
/// Until 2026-08-28 this initializer truncated to `SpokenSummary.detailCharacterLimit`,
/// on the reasoning that the read-back and the delivery were the same string and should
/// obey the same budget. They are not the same string: `InstructionDictation` already
/// reads back a *condensed* sentence ending in an ellipsis while queueing the full one,
/// so the cap here clipped only the agent's copy — silently turning "run the tests but
/// not the slow ones" into "run the tests but". The ratified rule (NARRATION_MODEL_PLAN,
/// rule 1) is that wearer input is never clipped: what the wearer dictated is what the
/// agent receives, on every backend path including Apple's. Read-back *to the wearer* may
/// still be abbreviated for speech; the agent's copy may not.
public struct QueuedInstruction: Sendable, Equatable {
    /// The instruction as it will be delivered, whole.
    public let text: String
    /// Whose sentence this is: the wearer's dictation, or TapQ's own deliberation loop
    /// acting on their behalf (M3).
    ///
    /// It rides the instruction rather than being re-derived at each hop because three
    /// unrelated places downstream need it and none of them can work it out for
    /// themselves: the origin-aware cap, which holds back autonomous instructions even
    /// where the dictated cap is stood down; the delivery template, which must tell the
    /// agent whether a human said this; and the enqueue result, which lets the read-back
    /// say differently when a loop sentence displaces one the wearer spoke.
    public let origin: InstructionOrigin
    /// When the instruction entered the queue, from the queue's clock.
    public let enqueuedAt: Date

    /// - Parameter origin: defaulted to `.dictated`, which is what every call site
    ///   written before the loop could queue anything meant by construction.
    public init(text: String, origin: InstructionOrigin = .dictated, enqueuedAt: Date) {
        self.text = SpokenSummaryText.normalized(text)
        self.origin = origin
        self.enqueuedAt = enqueuedAt
    }

    /// True when nothing survived normalization — a dictation that captured silence.
    public var isEmpty: Bool { text.isEmpty }
}

/// What an enqueue attempt did, in enough detail for the caller to diagnose it.
public enum InstructionEnqueueResult: Sendable, Equatable {
    /// Nothing was queued: the text was empty once normalized.
    case rejectedEmpty
    /// The instruction was appended, and nothing was lost.
    case queued(QueuedInstruction)
    /// The instruction was appended after the session's oldest waiting instruction was
    /// dropped to make room (RC2's drop-oldest rule).
    case queuedDroppingOldest(QueuedInstruction, dropped: QueuedInstruction)

    /// The instruction that is now waiting, or `nil` when nothing was queued.
    public var accepted: QueuedInstruction? {
        switch self {
        case .rejectedEmpty: return nil
        case let .queued(instruction): return instruction
        case let .queuedDroppingOldest(instruction, _): return instruction
        }
    }

    /// The instruction that was evicted to make room, or `nil` when nothing was lost.
    ///
    /// The mirror of ``accepted``, and it exists for the same reason plus one: since both
    /// sides now carry an ``InstructionOrigin``, a composition can see *which kind* of
    /// sentence displaced *which kind*. Announcing a loop-composed instruction that pushed
    /// out something the wearer said is a different sentence from announcing one that
    /// pushed out another of TapQ's own, and neither can be phrased from a `Bool`.
    public var displaced: QueuedInstruction? {
        switch self {
        case .rejectedEmpty, .queued: return nil
        case let .queuedDroppingOldest(_, dropped): return dropped
        }
    }
}

/// The instructions each session is waiting to receive, oldest first.
///
/// The shape mirrors ``AnsweredQuestionStore`` and ``SessionContextStore``: a `Sendable`
/// value type with `mutating` methods, owned by a `@MainActor` class, so the queue needs
/// no lock and no actor of its own.
///
/// One bound, per session: ``capacity`` instructions, dropping the *oldest* when a fifth
/// arrives. Dropping the oldest rather than refusing the newest is the ratified rule
/// (RC2) and it matches what dictation means — the wearer's most recent sentence is the
/// one they meant, and an instruction that has waited through four more is stale.
///
/// There is deliberately no bound on the number of tracked sessions, unlike
/// ``SessionContextStore``: a session's entry is removed the moment its last instruction
/// is delivered, so only sessions with undelivered instructions occupy space, and those
/// exist only because a wearer dictated into them by hand — or, from M3, because TapQ's
/// own loop composed one on their behalf, which is bounded by the same capacity and the
/// same drop-oldest rule.
public struct InstructionQueue: Sendable {
    /// Instructions retained per session before the oldest is dropped.
    public static let capacity = 4

    private var bySession: [String: [QueuedInstruction]] = [:]
    private let clock: @Sendable () -> Date

    /// - Parameter clock: the timestamp source for queued instructions. Tests inject a
    ///   fixed or stepping clock; the runtime takes the default wall clock.
    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    // MARK: - Writing

    /// Appends an instruction for `session`, dropping the oldest at capacity.
    ///
    /// - Parameter origin: whose sentence this is. Defaulted to `.dictated` so every call
    ///   site that predates the loop keeps saying what it always said.
    @discardableResult
    public mutating func enqueue(
        _ text: String,
        session: String,
        origin: InstructionOrigin = .dictated
    ) -> InstructionEnqueueResult {
        let instruction = QueuedInstruction(text: text, origin: origin, enqueuedAt: clock())
        guard !instruction.isEmpty else { return .rejectedEmpty }

        var waiting = bySession[session] ?? []
        waiting.append(instruction)
        guard waiting.count > Self.capacity else {
            bySession[session] = waiting
            return .queued(instruction)
        }
        let dropped = waiting.removeFirst()
        bySession[session] = waiting
        return .queuedDroppingOldest(instruction, dropped: dropped)
    }

    /// Removes and returns the session's oldest waiting instruction.
    ///
    /// The session's entry disappears with its last instruction, which is what keeps a
    /// long-running fleet from accumulating empty sessions.
    public mutating func dequeue(session: String) -> QueuedInstruction? {
        guard var waiting = bySession[session], !waiting.isEmpty else { return nil }
        let next = waiting.removeFirst()
        if waiting.isEmpty {
            bySession.removeValue(forKey: session)
        } else {
            bySession[session] = waiting
        }
        return next
    }

    /// Forgets everything queued for a session, returning what was discarded.
    @discardableResult
    public mutating func clear(session: String) -> [QueuedInstruction] {
        bySession.removeValue(forKey: session) ?? []
    }

    // MARK: - Reading

    /// The session's waiting instructions, oldest first. Empty for an unknown session.
    public func pending(session: String) -> [QueuedInstruction] {
        bySession[session] ?? []
    }

    /// The instruction the next boundary would take, without taking it.
    ///
    /// The origin-aware cap needs this: whether an instruction may be delivered now
    /// depends on whose sentence it is, so the decision has to see the head *before* it
    /// decides, and a cap that dequeued first and then held the value back would have to
    /// put it somewhere — which is exactly the "suppressed, never discarded" rule the
    /// caps already keep by leaving it in place.
    public func peek(session: String) -> QueuedInstruction? {
        bySession[session]?.first
    }

    /// How many instructions the session is waiting to receive.
    public func count(session: String) -> Int {
        bySession[session]?.count ?? 0
    }

    /// Whether the session has anything to receive at its next turn boundary.
    public func hasPending(session: String) -> Bool {
        count(session: session) > 0
    }

    /// Every session with at least one waiting instruction, in no defined order.
    public var trackedSessions: [String] { Array(bySession.keys) }
}

/// The runtime's one home for queued instructions.
///
/// Three unrelated call sites need the same queue — the dictation flow that enqueues
/// what the wearer said, the debug/SDK `instruction.submit` path, and the stop-question
/// coordinator that delivers at a turn boundary — so the queue cannot live as a `var`
/// captured into any one of them: a captured value type would be copied and each site
/// would write to a different memory. This is the reference type they share, for the
/// same reason the runtime's conversation memory is one.
///
/// Diagnostics are emitted here rather than from the value type, and they carry counts
/// and lengths only. The instruction's text is the wearer's speech; it belongs in the
/// read-back and in the reply to the agent, not in an operational log line.
@MainActor public final class InstructionMailbox {
    private var queue: InstructionQueue
    private let diagnostics: TapQDiagnosticEmitter

    /// Fired with the session id after an instruction is actually queued.
    ///
    /// One observer, one caller: the wait registry, which has to let go of a held turn
    /// boundary the moment there is something for it to carry. It lives here rather than at
    /// each enqueue site because there are three of those — the dictation flow, the wire's
    /// `instruction.submit`, and the voice-session window — and a boundary that woke for two
    /// of them and slept through the third would be a bug nobody could reproduce.
    ///
    /// Nothing is passed but the session: an observer's job is to notice that the queue
    /// changed, not to read what the wearer said.
    public var onEnqueued: (@MainActor (_ session: String) -> Void)?

    /// - Parameters:
    ///   - clock: timestamp source for queued instructions, injected by tests.
    ///   - diagnosticSink: where queue events go; the default drops them.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.queue = InstructionQueue(clock: clock)
        self.diagnostics = TapQDiagnosticEmitter(
            category: "Instruction",
            sink: diagnosticSink
        )
    }

    /// Queues an instruction for a session's next turn boundary.
    ///
    /// - Returns: what happened, in the three cases a caller can act on differently: nothing
    ///   was queued because the text was empty once normalized; the instruction is waiting;
    ///   or it is waiting and displaced the session's oldest. The third case used to be
    ///   folded into the second and visible only in the diagnostic log, which meant a wearer
    ///   dictating a fifth sentence lost their first one silently. The read-back says so now
    ///   (audible-refusal decision, 2026-08-28), and it can only say so if this tells it.
    ///
    /// - Parameter origin: whose sentence this is. `.dictated` by default, so the three
    ///   wearer-facing enqueue sites — the dictation flow, the wire's `instruction.submit`,
    ///   and the voice-session window — say what they have always said without naming it,
    ///   and only the loop has to be explicit about acting on its own.
    @discardableResult
    public func enqueue(
        _ text: String,
        session: String,
        origin: InstructionOrigin = .dictated
    ) -> InstructionEnqueueResult {
        let result = queue.enqueue(text, session: session, origin: origin)
        switch result {
        case .rejectedEmpty:
            diagnostics.record("instruction.rejected_empty", level: .warning, fields: [
                "session": session,
                "origin": origin.rawValue,
            ])
        case let .queued(instruction):
            diagnostics.record("instruction.queued", fields: [
                "session": session,
                "depth": "\(queue.count(session: session))",
                "length": "\(instruction.text.count)",
                "origin": instruction.origin.rawValue,
            ])
        case let .queuedDroppingOldest(instruction, dropped):
            // Both origins, because "TapQ's own sentence evicted one the wearer spoke" is
            // the case an operator reading this log actually wants to find.
            diagnostics.record("instruction.dropped_capacity", level: .warning, fields: [
                "session": session,
                "capacity": "\(InstructionQueue.capacity)",
                "dropped_length": "\(dropped.text.count)",
                "dropped_origin": dropped.origin.rawValue,
                "origin": instruction.origin.rawValue,
            ])
            diagnostics.record("instruction.queued", fields: [
                "session": session,
                "depth": "\(queue.count(session: session))",
                "length": "\(instruction.text.count)",
                "origin": instruction.origin.rawValue,
            ])
        }
        if result.accepted != nil { onEnqueued?(session) }
        return result
    }

    /// Takes the session's oldest waiting instruction, or `nil` when it has none.
    public func dequeue(session: String) -> QueuedInstruction? {
        guard let next = queue.dequeue(session: session) else { return nil }
        diagnostics.record("instruction.dequeued", fields: [
            "session": session,
            "remaining": "\(queue.count(session: session))",
            "origin": next.origin.rawValue,
        ])
        return next
    }

    /// Whether the session has an instruction waiting for its next turn boundary.
    public func hasPending(session: String) -> Bool {
        queue.hasPending(session: session)
    }

    /// How many instructions the session is waiting to receive. The status line reads
    /// this; so do tests.
    public func pendingCount(session: String) -> Int {
        queue.count(session: session)
    }

    /// The session's waiting instructions, oldest first.
    public func pending(session: String) -> [QueuedInstruction] {
        queue.pending(session: session)
    }

    /// What the next boundary would take, without taking it.
    ///
    /// The one reader is the coordinator's origin-aware cap, which has to know whose
    /// sentence it is about to hold back before it decides whether to hold it back.
    public func peek(session: String) -> QueuedInstruction? {
        queue.peek(session: session)
    }

    /// Discards everything queued for a session.
    @discardableResult
    public func clear(session: String) -> [QueuedInstruction] {
        let discarded = queue.clear(session: session)
        if !discarded.isEmpty {
            diagnostics.record("instruction.cleared", fields: [
                "session": session,
                "count": "\(discarded.count)",
            ])
        }
        return discarded
    }
}
