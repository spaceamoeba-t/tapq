import Foundation
import TapQContracts

/// One thing TapQ agreed to do when a named agent's next run finishes.
///
/// The wearer's sentence, the agent it waits on, and who asked for it. Nothing else: a
/// follow-up carries no compiled predicate, no cooldown key, and no time-to-live, because
/// it fires exactly once and is then gone. Those are the machinery a *standing* rule needs
/// to keep from firing forever, and the one-shot kernel does not have that problem to solve
/// (`docs/TAPQ_AGENT_PLAN.md`, "Initiative (M3, the guarded step)"; the standing-directive
/// layer is deferred, maintainer-ratified 2026-08-31).
public struct WearerFollowup: Sendable, Equatable {
    /// The agent's display name as it was set — the wearer's own word for it, or the
    /// roster's, depending on who set it. Never an opaque session identifier.
    public let agentDisplayName: String
    /// What to do at that agent's next finished boundary, in the words it was given in.
    public let instruction: String
    /// Who put it in the book: the wearer, by voice, or TapQ's own loop registering a
    /// continuation for work it just started.
    ///
    /// ``TapQContracts/InstructionOrigin`` rather than a second vocabulary of the same two
    /// words. The tag was declared for the M3 legs to share, and the distinction it draws —
    /// the wearer said this, or TapQ composed it — is exactly the one a follow-up needs. It
    /// says nothing about the *instruction a firing may queue*: that one is always
    /// ``TapQContracts/InstructionOrigin/loop``, because TapQ composed it, however the
    /// follow-up got here.
    public let origin: InstructionOrigin
    /// What kind of promise it is: something to *do*, or the reading-back of a result.
    /// See ``WearerFollowupPurpose``.
    public let purpose: WearerFollowupPurpose
    /// When it was set, from the book's clock.
    public let createdAt: Date

    public init(
        agentDisplayName: String,
        instruction: String,
        origin: InstructionOrigin,
        purpose: WearerFollowupPurpose = .instruction,
        createdAt: Date
    ) {
        self.agentDisplayName = agentDisplayName
        self.instruction = instruction
        self.origin = origin
        self.purpose = purpose
        self.createdAt = createdAt
    }
}

/// Why a follow-up is in the book — and, with it, whether hearing the agent's outcome
/// already keeps the promise.
///
/// Two purposes, and the book treats them differently at exactly one moment. A follow-up
/// that *does* something ("rerun the tests") is owed its firing however the boundary was
/// narrated: the wearer asked for an act, and an act is not discharged by a sentence. The
/// report-back TapQ arms for itself at every delivered instruction
/// (``WearerFollowupScheduler/armReportBack(agent:about:)``) promises only that the wearer
/// will *hear the result* — and when the boundary's own narration has just read the agent's
/// message out in full, the result has been heard and the promise is kept. Firing it then
/// reads the same thing twice.
///
/// Fifth hardware run (2026-09-02): "run git status" reached Claude Code, and the wearer
/// heard its outcome as their own question's answer, as the stop question TapQ asked them,
/// as the narrated final message, and then a fourth time when the report-back fired on top
/// of all three. The origin tag cannot tell those apart — the loop's own `set_followup`
/// continuations are `.loop` too, and those are acts — so the purpose is its own field.
public enum WearerFollowupPurpose: String, Sendable, Equatable {
    /// An instruction to carry out at the boundary. The default, and every follow-up the
    /// wearer or the loop sets by name.
    case instruction
    /// TapQ's own promise to read the result back. Discharged silently when the wearer
    /// has already heard it — see ``WearerFollowupBook/noteOutcomeHeard(agent:)``.
    case reportBack = "report_back"
}

/// The boundary that woke a follow-up, as the review model reads it.
///
/// Three fields, and the third is the dangerous one. ``summary`` is agent output: it is a
/// record of what the agent did, it was not written for TapQ, and the guardrail in the plan
/// is absolute — boundary content can never create, modify, re-confirm, or cancel a
/// follow-up. That is enforced structurally rather than by prompt alone (nothing on this
/// path reads the boundary into the book), and the prompt states it as well because the
/// model is the one thing that reads both halves. See
/// ``WearerTaskContract/followupInstructions`` and the separate labelling in
/// ``WearerTaskContract/input(for:)``.
public struct WearerFollowupBoundary: Sendable, Equatable {
    /// Whose boundary it was.
    public let agentDisplayName: String
    /// What happened, in the runtime's own short words — "finished", "is waiting on you".
    /// A free string rather than a closed set: the notification chokepoint that supplies it
    /// has its own vocabulary, and a second enum here would be a copy that drifts.
    public let event: String
    /// The one line TapQ would have narrated about it. **Untrusted agent output.**
    public let summary: String

    public init(agentDisplayName: String, event: String, summary: String) {
        self.agentDisplayName = agentDisplayName
        self.event = event
        self.summary = summary
    }
}

/// The lifecycle words the durable record keeps, in the `outcome` field of a `followup`
/// entry.
///
/// Strings rather than an enum for the reason ``WearerDialogueKind`` is an open string: they
/// are written to a file a later build reads, and a word this build does not recognize must
/// render as itself rather than fail the line.
public enum WearerFollowupEvent {
    /// Set, with nothing there before.
    public static let created = "created"
    /// Set over one that was already pending for the same agent. One entry, carrying the
    /// *new* sentence — the old one is already on the record from its own `created` line.
    public static let replaced = "replaced"
    /// Dropped before it fired.
    public static let cancelled = "cancelled"
    /// Dropped *during* the announce grace: it had come due and been taken out of the book,
    /// the wearer heard what TapQ was about to do, and they said no in time. Its own word,
    /// because "cancelled" would tell a wearer asking tomorrow that nothing had happened,
    /// and something did — TapQ spoke.
    public static let aborted = "aborted"
    /// The runtime or the voice session ended with it still pending. In-memory only, so
    /// this is where a follow-up goes when the process does.
    public static let expired = "expired"
    /// It came due and the loop was already working on something else, so it did not run.
    public static let notRunBusy = "not run: busy"
    /// A finished boundary came and the follow-up stayed in the book, because the turn that
    /// ended had launched background work that was still running — the boundary was the
    /// agent's turn ending, not the work the wearer meant. It fires at the next one.
    public static let heldWorkRunning = "held: work still running"
    /// A report-back that came due after the boundary's own narration had already read the
    /// agent's message out in full. The promise was to make the result heard, and it was;
    /// nothing fired, nothing was spoken.
    public static let dischargedHeard = "discharged: already heard"
    /// It fired and the review ended in this outcome.
    public static func fired(_ outcome: WearerTaskOutcome) -> String {
        "fired: " + outcome.rawValue
    }
    /// It fired and a cloud call inside the review failed. Its own word rather than
    /// ``fired(_:)`` with ``WearerTaskOutcome/broken``, because the disposition the engine
    /// returns for that case is its own too — see ``WearerFollowupDisposition/broke(reason:)``.
    public static let firedBroken = "fired: broken"
}

/// What became of one follow-up handed to the engine
/// (``WearerTaskLoop/runFollowup(_:boundary:surfaces:)``).
///
/// Its own type rather than three more cases on ``TapQContracts/WearerTaskStart``, and the
/// reason is that `WearerTaskStart` is a *spoken* contract: both its cases carry a sentence
/// the caller says out loud, because both are answers to a wearer who has just spoken. A
/// follow-up has nobody to answer. Two of the three cases below must produce no sound at
/// all, and putting them in a contract whose whole shape is "here is what to say" would be
/// an invitation to say something.
public enum WearerFollowupDisposition: Sendable, Equatable {
    /// The review ran to an ending. Whatever it had to say, it has already said.
    ///
    /// Never ``WearerTaskOutcome/broken`` — that is ``broke(reason:)`` below — and never
    /// ``WearerTaskOutcome/unanswered``, because the lane declares no `ask_wearer`.
    case ran(WearerTaskOutcome)
    /// The task slot was busy, so nothing ran and nothing was spoken.
    ///
    /// Deliberately not ``WearerTaskLoop/busyNotice``: that sentence answers a wearer who
    /// just asked for something ("I'm still on the last thing you asked"), and speaking it
    /// here would be TapQ interrupting someone to report its own scheduling. The composition
    /// decides — set the follow-up again and try at the next boundary, or give up audibly.
    case busy
    /// A cloud call inside the review failed. Nothing was spoken and the voice latch was
    /// **not** touched.
    ///
    /// The engine reports; the composition latches. On the task lane the loop breaks the
    /// voice itself through `onLoopBroken`, because a wearer is waiting on a task they
    /// started and the pipe they were promised an answer on is gone. Here the gate that
    /// invoked the review is the thing that owns the latch — it is the same object that
    /// refuses to invoke a review while the latch is already broken — and a second authority
    /// breaking it from underneath would make "why did the voice break" answerable two ways.
    case broke(reason: String)

    /// The word the durable record keeps for this ending
    /// (``WearerFollowupBook/recordFiring(_:disposition:)``).
    public var recordedEvent: String {
        switch self {
        case .ran(let outcome): return WearerFollowupEvent.fired(outcome)
        case .busy: return WearerFollowupEvent.notRunBusy
        case .broke: return WearerFollowupEvent.firedBroken
        }
    }
}

/// What ``WearerFollowupBook/set(agent:instruction:origin:)`` did.
///
/// Three cases and not a `Bool`, because the composition speaks a different sentence for
/// each: a replacement has to be audible ("that replaces the last one") or the wearer is
/// left believing they have two, and a set that took nothing has to say so rather than
/// letting them believe TapQ is watching.
public enum WearerFollowupOutcome: Sendable, Equatable {
    /// Nothing was pending for that agent; this one is now.
    case created(WearerFollowup)
    /// One was pending for that agent and has been replaced by this one.
    case replaced(WearerFollowup, previous: WearerFollowup)
    /// Nothing was set: the agent name or the sentence was empty.
    case notSet(reason: String)
}

/// What ``WearerFollowupBook/cancel(agent:)`` found.
public enum WearerFollowupCancellation: Sendable, Equatable {
    /// It was pending and is now gone.
    case cancelled(WearerFollowup)
    /// It had already come due and was inside its announce grace. The action it would have
    /// taken has been aborted and never reaches an agent.
    case aborted(WearerFollowup)
    /// Nothing was pending for that name.
    ///
    /// Named rather than spelled `none`, which would shadow `Optional.none` at every
    /// comparison site and make a test read as though it were checking for nil.
    case nothingPending
}

/// A follow-up taken out of the book and not yet acted on.
///
/// The gap this exists to cover is the announce-then-act grace the plan requires: TapQ says
/// out loud what it is about to do and waits a beat, so a spoken "no" retracts it before it
/// lands. During that beat the follow-up is in neither place — it is out of the book (so a
/// second boundary cannot fire it twice) and not yet delivered (so a cancel must still be
/// able to stop it). This token is that third place, and ``claim()`` is the atomic
/// check-and-take at the end of the grace.
///
/// A class, and identity is the point: the book holds the same object the caller does, so a
/// ``WearerFollowupBook/cancel(agent:)`` arriving mid-grace reaches through it.
@MainActor public final class WearerFollowupDelivery {
    /// What was taken out.
    public let followup: WearerFollowup

    /// Whether a cancel arrived before the grace ran out.
    public private(set) var isAborted = false
    /// Whether this token has been resolved either way, so neither claim nor abort can run
    /// twice.
    public private(set) var isSettled = false

    /// Set by the book so it can forget the token the moment it settles. Not the caller's.
    var onSettled: (@MainActor () -> Void)?

    init(followup: WearerFollowup) {
        self.followup = followup
    }

    /// Takes the follow-up if the grace passed without a cancel, or `nil` if one arrived.
    ///
    /// The caller acts on what comes back and does nothing at all on `nil` — the cancel that
    /// beat it has already spoken and recorded, so a second sentence here would report one
    /// event twice.
    @discardableResult
    public func claim() -> WearerFollowup? {
        guard !isSettled else { return nil }
        isSettled = true
        onSettled?()
        return followup
    }

    /// The cancel path. Internal: only the book aborts a delivery, because only the book
    /// knows a cancel arrived for that name.
    @discardableResult
    func abort() -> Bool {
        guard !isSettled else { return false }
        isSettled = true
        isAborted = true
        onSettled?()
        return true
    }
}

/// The one-shot follow-up kernel: at most one pending follow-up per agent, fired once at
/// that agent's next finished boundary and then gone (`docs/TAPQ_AGENT_PLAN.md`,
/// "Initiative (M3, the guarded step)", scoped to one-shots by the maintainer 2026-08-31).
///
/// ## What it is, and what it deliberately is not
///
/// The wearer says "when Claude Code finishes, rerun the tests", or a running deliberation
/// task registers its own continuation, and the book holds that one sentence until Claude
/// Code's next run finishes. Then it is consumed, the loop wakes once in its own narrow
/// mode (``WearerTaskLoop/runFollowup(_:boundary:surfaces:)``), and the book is empty again.
///
/// It is not the standing-directive layer that section describes. There is no envelope
/// compilation, no predicate, no cooldown or dedup key, no time-to-live, no read-back of a
/// canonical paraphrase, and no three-live cap — every one of those exists to bound a rule
/// that fires *repeatedly*, and a one-shot has no such thing to bound. What does carry over
/// unchanged, because it applies to a single firing just as much: the gate runs before any
/// model call, the review's tool set is narrowed rather than switched off, gate refusals are
/// silent and logged, and every autonomous act is announced.
///
/// ## Three semantics worth stating plainly
///
/// **A follow-up set while the agent is already parked fires on the *next* boundary.** If
/// Claude Code is sitting at a held Stop question when the wearer says "when Claude Code
/// finishes, rerun the tests", nothing fires retroactively off the boundary that is already
/// held. The follow-up waits for the next *finished* event — in practice the run that
/// TapQ's own answer or instruction sets going. That is the honest reading of "when it
/// finishes": the wearer means the work in front of them, not the pause they are standing in.
///
/// **A follow-up cannot re-fire off the boundary its own instruction caused.** This is the
/// provenance loop-breaker the plan names, and here it needs no rule: the follow-up is
/// consumed at the moment it fires, so by the time the instruction it queued reaches the
/// agent and that run finishes, there is nothing in the book for that agent. The one-shot
/// design makes the loop structurally impossible rather than filtered — there is no state
/// for a second firing to read. (A *replacement* set during the review would be a new
/// follow-up the wearer or the loop asked for, and firing on the next boundary is exactly
/// what it asked for. The review lane cannot set one: `set_followup` is undeclared there,
/// which is what keeps a chain from composing itself.)
///
/// **In memory only, on purpose, for v1.** A follow-up does not survive a runtime restart.
/// It is a promise about a run that is happening now, made minutes ago, and a promise
/// reloaded from disk hours later would fire against a boundary the wearer has long stopped
/// caring about — with no wearer in the loop to say so, because the process that heard them
/// is gone. Durability is a decision for the standing-directive layer, which has a TTL to
/// make it safe. What *is* durable is the record: every lifecycle event below is written to
/// Pillar A, so a wearer who asks tomorrow finds out that a follow-up existed and what
/// became of it, including that it expired when the runtime stopped.
///
/// ## The record
///
/// Every lifecycle event — created, replaced, cancelled, aborted, expired, fired with its
/// outcome — goes through one injected non-throwing closure, and this type is the only
/// writer of `followup` entries. A single writer is what keeps the file's story of a
/// follow-up complete: an engine that recorded its own endings would leave the ones that
/// never reached the engine (a cancel, an expiry) to a second author.
@MainActor public final class WearerFollowupBook {
    /// Records one lifecycle event: which agent, the sentence, and what happened to it.
    ///
    /// Non-throwing for the reason every ``WearerTaskSurfaces`` closure is: a record that
    /// could not be written is a local file problem, and a local file problem never breaks
    /// the wearer's voice.
    public typealias Recorder =
        @MainActor (_ agentDisplayName: String, _ instruction: String, _ event: String) -> Void

    private let clock: @Sendable () -> Date
    private let record: Recorder
    private let diagnostics: TapQDiagnosticEmitter

    /// Keyed by the folded name, valued by the follow-up with the name as it was given.
    private var pending: [String: WearerFollowup] = [:]
    /// Deliveries taken out of the book and still inside their announce grace.
    private var inFlight: [String: WearerFollowupDelivery] = [:]
    /// Agents whose pending report-back has been kept by the boundary's own narration, and
    /// is waiting only for that boundary's finished notification to discharge it. Folded
    /// keys. Cleared by anything that changes what is pending for the agent.
    private var heard: Set<String> = []

    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        record: @escaping Recorder = { _, _, _ in },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.clock = clock
        self.record = record
        self.diagnostics = TapQDiagnosticEmitter(category: "WearerFollowup", sink: diagnosticSink)
    }

    // MARK: - Setting

    /// Puts one follow-up in the book, replacing whatever was there for that agent.
    ///
    /// One per agent, and the replacement is not an error: a wearer who says "actually, when
    /// Claude finishes, just tell me what broke" means that instead of what they said a
    /// minute ago, and a book that kept both would fire twice at one boundary. What the
    /// replacement must not be is *silent* — the returned case says so, and the composition
    /// speaks it.
    @discardableResult
    public func set(
        agent: String,
        instruction: String,
        origin: InstructionOrigin,
        purpose: WearerFollowupPurpose = .instruction
    ) -> WearerFollowupOutcome {
        let agent = SpokenSummaryText.normalized(agent)
        let instruction = SpokenSummaryText.normalized(instruction)
        guard !agent.isEmpty else {
            diagnostics.record("set.rejected", fields: ["reason": "no_agent"])
            return .notSet(reason: "no agent")
        }
        guard !instruction.isEmpty else {
            diagnostics.record("set.rejected", fields: [
                "reason": "no_instruction",
                "agent": agent,
            ])
            return .notSet(reason: "no instruction")
        }

        let key = Self.key(agent)
        let followup = WearerFollowup(
            agentDisplayName: agent,
            instruction: instruction,
            origin: origin,
            purpose: purpose,
            createdAt: clock()
        )
        let previous = pending[key]
        pending[key] = followup
        heard.remove(key)
        let event = previous == nil ? WearerFollowupEvent.created : WearerFollowupEvent.replaced
        diagnostics.record("set", fields: [
            "agent": agent,
            "origin": origin.rawValue,
            "length": "\(instruction.count)",
            "replaced": "\(previous != nil)",
            "pending": "\(pending.count)",
        ])
        record(agent, instruction, event)
        guard let previous else { return .created(followup) }
        return .replaced(followup, previous: previous)
    }

    // MARK: - Reading

    /// What is waiting on that agent, or `nil`.
    ///
    /// The gate's first question, and it is deliberately a *peek*: a boundary that will be
    /// refused for some other reason — the latch is broken, the loop is busy, the boundary
    /// was TapQ's own — must not consume the follow-up on its way to being refused.
    public func pending(for agent: String) -> WearerFollowup? {
        pending[Self.key(agent)]
    }

    /// Every follow-up in the book, in the order they were set. For `get_status` and tests.
    public func all() -> [WearerFollowup] {
        pending.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// How many are waiting.
    public var count: Int { pending.count }

    // MARK: - Firing

    /// Takes the follow-up for that agent out of the book, if there is one.
    ///
    /// The token that comes back is not yet an action: the composition announces what TapQ
    /// is about to do, waits its grace, and then calls ``WearerFollowupDelivery/claim()``.
    /// Between those two moments a ``cancel(agent:)`` aborts it and nothing is delivered.
    ///
    /// Taking it out *before* the announcement rather than after is what makes a second
    /// boundary arriving mid-grace harmless: there is nothing left in the book for it to
    /// fire.
    public func consume(agent: String) -> WearerFollowupDelivery? {
        let key = Self.key(agent)
        guard let followup = pending.removeValue(forKey: key) else { return nil }
        heard.remove(key)
        // A delivery already in flight for the same agent is settled first. It cannot be
        // claimed any more — its boundary is gone — and leaving it in the table would let a
        // later cancel abort the wrong one.
        inFlight[key]?.abort()
        let delivery = WearerFollowupDelivery(followup: followup)
        delivery.onSettled = { [weak self, weak delivery] in
            guard let self, let delivery, self.inFlight[key] === delivery else { return }
            self.inFlight[key] = nil
        }
        inFlight[key] = delivery
        diagnostics.record("consumed", fields: [
            "agent": followup.agentDisplayName,
            "origin": followup.origin.rawValue,
            "pending": "\(pending.count)",
        ])
        return delivery
    }

    /// Records how a fired follow-up ended.
    ///
    /// Called by the composition once ``WearerTaskLoop/runFollowup(_:boundary:surfaces:)``
    /// returns. The engine writes diagnostics and speaks; it does not write to Pillar A,
    /// because this type is the single writer of `followup` entries and a second author
    /// would make the file's account of one follow-up depend on which path it took.
    public func recordFiring(
        _ followup: WearerFollowup,
        disposition: WearerFollowupDisposition
    ) {
        diagnostics.record("fired", fields: [
            "agent": followup.agentDisplayName,
            "origin": followup.origin.rawValue,
            "event": disposition.recordedEvent,
        ])
        record(followup.agentDisplayName, followup.instruction, disposition.recordedEvent)
    }

    /// Records that a finished boundary was *not* taken as the one this follow-up waits for.
    ///
    /// The book is untouched — the promise stays armed for the next boundary — and the
    /// record gets a line, because a wearer who heard "finished" and then heard nothing
    /// about their follow-up needs the file to say why when they ask tomorrow. Nothing is
    /// recorded when nothing is pending: the gate peeks first.
    public func recordHeld(agent: String) {
        guard let followup = pending[Self.key(agent)] else { return }
        // Whatever was narrated at this boundary was the turn ending, not the work; the
        // result is still to come, so a report-back is owed it after all.
        heard.remove(Self.key(agent))
        diagnostics.record("held", fields: [
            "agent": followup.agentDisplayName,
            "origin": followup.origin.rawValue,
            "reason": "work_running",
        ])
        record(followup.agentDisplayName, followup.instruction,
               WearerFollowupEvent.heldWorkRunning)
    }

    // MARK: - Already heard

    /// Notes that the boundary now ending has read the agent's message to the wearer in
    /// full, so a report-back waiting on that agent has nothing left to report.
    ///
    /// A mark, not a discharge, because this is called from the narration — which happens
    /// *before* the finished notification that says what kind of boundary it was. If that
    /// notification turns out to be a turn that left work running, ``recordHeld(agent:)``
    /// clears the mark and the report-back waits for the real result. Only a
    /// ``WearerFollowupPurpose/reportBack`` is ever marked: a wearer's own follow-up asks
    /// for an act, and hearing a sentence does not perform it.
    public func noteOutcomeHeard(agent: String) {
        let key = Self.key(agent)
        guard let followup = pending[key], followup.purpose == .reportBack else { return }
        heard.insert(key)
        diagnostics.record("heard", fields: ["agent": followup.agentDisplayName])
    }

    /// Takes a marked report-back out of the book at the finished boundary, recording that
    /// it was discharged rather than fired. `nil` when nothing was marked — the gate then
    /// goes on to fire whatever is pending as usual.
    ///
    /// Silent by design, and this is the one silence the kernel allows itself: the wearer
    /// heard "I'll report back", then heard the result, then heard "finished". A sentence
    /// here about *not* repeating it would be the repetition it exists to prevent.
    @discardableResult
    public func dischargeHeard(agent: String) -> WearerFollowup? {
        let key = Self.key(agent)
        guard heard.remove(key) != nil, let followup = pending[key],
              followup.purpose == .reportBack
        else { return nil }
        pending.removeValue(forKey: key)
        diagnostics.record("discharged", fields: [
            "agent": followup.agentDisplayName,
            "reason": "already_heard",
            "pending": "\(pending.count)",
        ])
        record(followup.agentDisplayName, followup.instruction,
               WearerFollowupEvent.dischargedHeard)
        return followup
    }

    // MARK: - Ending

    /// Drops the follow-up for one agent, wherever it currently is.
    ///
    /// Two places, and both have to answer to this: pending in the book, or out of it and
    /// inside its announce grace. The second is the whole reason the grace exists — the
    /// wearer heard TapQ say what it was about to do and said no — so a cancel that only
    /// looked at the book would be a cancel that arrived at exactly the moment it could not
    /// work.
    @discardableResult
    public func cancel(agent: String) -> WearerFollowupCancellation {
        let key = Self.key(agent)
        if let followup = pending.removeValue(forKey: key) {
            heard.remove(key)
            inFlight[key]?.abort()
            diagnostics.record("cancelled", fields: [
                "agent": followup.agentDisplayName,
                "stage": "pending",
                "pending": "\(pending.count)",
            ])
            record(followup.agentDisplayName, followup.instruction,
                   WearerFollowupEvent.cancelled)
            return .cancelled(followup)
        }
        if let delivery = inFlight[key], delivery.abort() {
            diagnostics.record("cancelled", fields: [
                "agent": delivery.followup.agentDisplayName,
                "stage": "grace",
                "pending": "\(pending.count)",
            ])
            record(delivery.followup.agentDisplayName, delivery.followup.instruction,
                   WearerFollowupEvent.aborted)
            return .aborted(delivery.followup)
        }
        diagnostics.record("cancel.nothing", fields: ["agent": agent])
        return .nothingPending
    }

    /// Empties the book because the session or the runtime is ending.
    ///
    /// Every pending follow-up is recorded as expired and every delivery still in its grace
    /// is aborted, so nothing lands on an agent after the thing that promised it is gone.
    /// Silent, for the reason ``WearerTaskLoop/cancel(reason:)`` is silent: both callers are
    /// endings, and the channel a sentence would go out on is being torn down in the same
    /// breath. The record still gets every line.
    public func expireAll(reason: String = "session ended") {
        let expiring = all()
        let graced = inFlight.values
        pending.removeAll()
        guard !expiring.isEmpty || !graced.isEmpty else { return }
        diagnostics.record("expired", fields: [
            "reason": reason,
            "pending": "\(expiring.count)",
            "in_flight": "\(graced.count)",
        ])
        for delivery in graced where delivery.abort() {
            record(delivery.followup.agentDisplayName, delivery.followup.instruction,
                   WearerFollowupEvent.expired)
        }
        inFlight.removeAll()
        for followup in expiring {
            record(followup.agentDisplayName, followup.instruction,
                   WearerFollowupEvent.expired)
        }
    }

    // MARK: - Names

    /// How two spellings of one agent become one entry.
    ///
    /// Folded on case and surrounding space, and nothing more. This is emphatically *not* a
    /// name resolver: which names are addressable is the roster's question, answered by rung
    /// E's resolver at the composition, and a book that did its own matching would be a
    /// second grammar for agent names. What it does have to get right is that the wearer's
    /// "claude code" and the roster's "Claude Code" are one agent, because the name goes in
    /// by voice and comes out of a notification.
    static func key(_ agent: String) -> String {
        SpokenSummaryText.normalized(agent).lowercased()
    }
}
