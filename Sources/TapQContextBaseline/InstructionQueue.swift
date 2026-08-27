import Foundation
import TapQContracts

/// One dictated instruction, waiting for the agent's next turn boundary.
///
/// The text is the wearer's own words, normalized and capped in this initializer so no
/// caller can put a paragraph — or a newline that would break a read-back — into a
/// queue entry. Like ``SessionContextEvent``, the type has nowhere to put a `toolInput`,
/// a `cwd`, or a `permissionMode`: an instruction is something the wearer said out loud
/// and TapQ read back to them, and nothing else ever reaches it.
public struct QueuedInstruction: Sendable, Equatable {
    /// Budget for one instruction. Shared with ``SpokenSummary/detailCharacterLimit``
    /// because an instruction is read back before it is queued: what the wearer hears
    /// and what the agent receives are the same string, so they obey the same cap.
    public static let textCharacterLimit = SpokenSummary.detailCharacterLimit

    /// The instruction as it will be read back and delivered.
    public let text: String
    /// When the instruction entered the queue, from the queue's clock.
    public let enqueuedAt: Date

    public init(text: String, enqueuedAt: Date) {
        self.text = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(text),
            limit: Self.textCharacterLimit
        )
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
/// exist only because a wearer dictated into them by hand.
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
    @discardableResult
    public mutating func enqueue(_ text: String, session: String) -> InstructionEnqueueResult {
        let instruction = QueuedInstruction(text: text, enqueuedAt: clock())
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
    /// - Returns: the queued instruction, or `nil` when the text was empty once
    ///   normalized — the caller then has something to say to the wearer rather than a
    ///   silent no-op.
    @discardableResult
    public func enqueue(_ text: String, session: String) -> QueuedInstruction? {
        let result = queue.enqueue(text, session: session)
        switch result {
        case .rejectedEmpty:
            diagnostics.record("instruction.rejected_empty", level: .warning, fields: [
                "session": session,
            ])
        case let .queued(instruction):
            diagnostics.record("instruction.queued", fields: [
                "session": session,
                "depth": "\(queue.count(session: session))",
                "length": "\(instruction.text.count)",
            ])
        case let .queuedDroppingOldest(instruction, dropped):
            diagnostics.record("instruction.dropped_capacity", level: .warning, fields: [
                "session": session,
                "capacity": "\(InstructionQueue.capacity)",
                "dropped_length": "\(dropped.text.count)",
            ])
            diagnostics.record("instruction.queued", fields: [
                "session": session,
                "depth": "\(queue.count(session: session))",
                "length": "\(instruction.text.count)",
            ])
        }
        if result.accepted != nil { onEnqueued?(session) }
        return result.accepted
    }

    /// Takes the session's oldest waiting instruction, or `nil` when it has none.
    public func dequeue(session: String) -> QueuedInstruction? {
        guard let next = queue.dequeue(session: session) else { return nil }
        diagnostics.record("instruction.dequeued", fields: [
            "session": session,
            "remaining": "\(queue.count(session: session))",
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
