import Foundation
import TapQContextBaseline
import TapQContracts
import TapQInteractionBaseline

/// One rule for what happens to a sentence the wearer means for an agent
/// (`docs/WAKE_WORD_PLAN.md` §4).
///
/// Three doors reach it — a plain sentence dictated in a window, a `queue_instruction` tool
/// call that names nobody, and `start_task` → `start_session` — and before this they
/// answered differently. A dictation with nothing live said "That wasn't queued after all";
/// the tool call said "An agent name is required"; only the third started anything. The
/// wearer said the same thing to the same machine in all three, so there is one function
/// and the doors are doors.
///
/// The decision is two questions in order:
///
/// 1. **Is something live to receive it?** Live is the roster's judgement and nothing else
///    (`ConversationMemory.liveStandingTarget`) — a session that exited an hour ago is not a
///    mailbox, it is a hole. If yes, the sentence is queued exactly as it always was.
/// 2. **Can TapQ start something?** With no launcher composed the honest answer is a
///    refusal that says so, and it is spoken. Otherwise the sentence becomes a new
///    session's goal, and what the wearer hears is that a session started — not that a
///    sentence was queued, because nothing was.
///
/// Portable on purpose: the decision is the part worth pinning in tests, and it names no
/// launcher, no roster, and no window. What is behind each closure is the runtime's
/// business.
@MainActor public struct InstructionRouter {
    /// What starting a session did, in the two terms this decision needs. The runtime's own
    /// richer result (which folder, which session id, what it displaced) is not this type's
    /// business — only whether the wearer is owed "a session started" or a sentence saying
    /// why not.
    public enum SessionStart: Sendable, Equatable {
        case started(agentDisplayName: String)
        /// Already a wearer-ready sentence, composed by whoever refused
        /// (``TapQContracts/OwnedSessionRefusal/spoken`` in the shipping composition).
        case refused(spoken: String)
    }

    /// Said when nothing is running and this run cannot start anything either — no owned
    /// launcher was composed, because the hooks, the mailbox, or the task reasoner this run
    /// was given do not add up to one.
    ///
    /// Both halves are load-bearing. "Nothing is running" is why the sentence was not
    /// queued; "TapQ cannot start Claude Code here" is why it did not become a session
    /// instead. A wearer who hears only the first would say it again, louder.
    /// Whether a spoken name is the agent TapQ can start — Claude Code — by the roster's
    /// own rule (the full display name, or its first word) plus the recognizer's usual
    /// mishearing of it. With nothing live, "tell Claude to …" is not an unknown agent;
    /// it names the session that is about to exist (2026-09-04, the second wake-word
    /// window: `queue_instruction` came back with agent "Claude" and the sentence was
    /// discarded as unaddressable).
    public nonisolated static func namesStartableAgent(_ spoken: String) -> Bool {
        let normalized = spoken.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["claude", "claudecode", "cloud", "cloudcode"].contains(normalized)
    }

    public nonisolated static let nothingToReceiveRefusal =
        "Nothing is running, and TapQ cannot start Claude Code here."

    /// Queues into the live standing target, or answers `nil` when there is none. `nil` is
    /// the whole of question 1: this closure, not the router, owns what "live" means.
    private let enqueueToLiveTarget: @MainActor (String) -> InstructionQueueOutcome?
    /// Starts a session for the sentence. `nil` — no launcher in this run — is question 2.
    private let startSession: (@MainActor (String) -> SessionStart)?
    private let diagnostics: TapQDiagnosticEmitter

    public init(
        enqueueToLiveTarget: @escaping @MainActor (String) -> InstructionQueueOutcome?,
        startSession: (@MainActor (String) -> SessionStart)?,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.enqueueToLiveTarget = enqueueToLiveTarget
        self.startSession = startSession
        self.diagnostics = TapQDiagnosticEmitter(category: "Instruction", sink: diagnosticSink)
    }

    /// The routing rule. Never throws and never returns silently: every arm is a sentence
    /// the wearer can be told.
    public func route(_ text: String) -> InstructionQueueOutcome {
        if let outcome = enqueueToLiveTarget(text) {
            diagnostics.record("routed", fields: ["to": "live"])
            return outcome
        }
        guard let startSession else {
            diagnostics.record("routed", level: .warning, fields: ["to": "refused"])
            return .refused(spoken: Self.nothingToReceiveRefusal)
        }
        switch startSession(text) {
        case .started(let agentDisplayName):
            diagnostics.record("routed", fields: ["to": "started"])
            return .startedSession(agentDisplayName: agentDisplayName)
        case .refused(let spoken):
            diagnostics.record("routed", level: .warning, fields: ["to": "start_refused"])
            return .refused(spoken: spoken)
        }
    }

    /// The routing closure a command window takes, so a wake window's dictation flow and the
    /// loop's tool call are the same call.
    public var dictating: InstructionDictating {
        { [self] text in route(text) }
    }

    // MARK: - Door 2

    /// What the loop's `queue_instruction` answers with when it named nobody and routed the
    /// sentence here instead (§4, door 2).
    ///
    /// The model gets a fact and an instruction about what to do next; the wearer gets the
    /// sentence. Both halves matter on this path more than on the named one: a sentence
    /// delivered — or an agent *started* — in the wearer's name while they are not
    /// listening has to be audible at the moment it happens.
    ///
    /// - Parameter liveAgentDisplayName: who the sentence was queued for, when it was.
    ///   Absent on every arm that did not queue, and "the agent" is the honest stand-in for
    ///   a composition that queued without knowing a name.
    public static func toolOutput(
        for outcome: InstructionQueueOutcome,
        instruction: String,
        liveAgentDisplayName: String?
    ) -> WearerTaskToolOutput {
        let target = liveAgentDisplayName ?? "the agent"
        switch outcome {
        case .queued:
            return .announcing(
                "Queued for \(target); it is delivered at that agent's next turn boundary. "
                    + "It authorizes nothing on its own.",
                say: "I've told \(target): " + WearerTaskLoop.spokenGoal(instruction)
            )
        case .queuedDroppingOldest:
            return .announcing(
                "Queued for \(target); the queue was full, so its oldest waiting "
                    + "instruction was dropped to make room. It authorizes nothing on its "
                    + "own.",
                say: "I've told \(target): " + WearerTaskLoop.spokenGoal(instruction)
                    + " — the oldest waiting instruction was dropped to make room."
            )
        case .notQueued:
            return .ok("\(target) would not take it, so nothing was queued.")
        case .startedSession(let agentDisplayName):
            return .announcing(
                "A new \(agentDisplayName) session was started for that sentence, because "
                    + "nothing was live to receive it. Finish by saying so in a few words.",
                say: "Started a new \(agentDisplayName) session: "
                    + WearerTaskLoop.spokenGoal(instruction)
            )
        case .refused(let spoken):
            // The reason is spoken once, by TapQ, in the sentence whoever refused composed.
            // The model is told not to say it again: two versions of the same bad news, the
            // second one paraphrased, is how a refusal stops sounding like one.
            return .announcing(
                "Nothing was queued and nothing was started. The wearer has been told why. "
                    + "Finish with a few words; do not repeat the reason.",
                say: spoken
            )
        }
    }
}
