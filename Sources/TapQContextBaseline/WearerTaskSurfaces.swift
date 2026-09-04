import Foundation
import TapQContracts

/// A local file that would not answer, in the two vocabularies it needs.
///
/// A memory file that will not open or a transcript that rotated is a *local* problem:
/// loud in the log at error level, honest in what the model is told, and emphatically not a
/// reason to end the wearer's session (`docs/TAPQ_AGENT_PLAN.md`, failure posture). Only
/// cloud calls break the voice.
public struct WearerTaskLocalFailure: Sendable, Equatable {
    /// Operator-facing, for the error-level diagnostic. Never wearer speech, never agent
    /// output, never the key.
    public let reason: String
    /// The sentence TapQ would say about it. Carried rather than spoken on the spot: the
    /// model has already been told, and in most cases it says something better in its own
    /// summary. It becomes the spoken sentence only where nothing else will be said — see
    /// ``WearerTaskLoop/answerWorkQuestion(question:agentDisplayName:)``.
    public let wearerNotice: String

    public init(reason: String, wearerNotice: String) {
        self.reason = reason
        self.wearerNotice = wearerNotice
    }
}

/// What one internal tool answered.
///
/// Three fields rather than a string, because the loop has to do three different things
/// with what a tool returns and only one of them is "hand it to the model":
///
/// - ``text`` is the model's, and only the model's. It is never spoken.
/// - ``announce`` is the wearer's, spoken verbatim the moment the tool returns. It exists
///   for one rule: an instruction the loop sent to an agent is audible, always. The wearer
///   handed over a goal, not the right to have sentences delivered in their name without
///   hearing about it.
/// - ``localFailure`` is the operator's, and the fallback sentence if the task ends with
///   nothing better to say.
public struct WearerTaskToolOutput: Sendable, Equatable {
    /// What the model reads. Always present — a tool that answered nothing still says so.
    public let text: String
    /// Spoken verbatim before the next turn, or `nil` when the tool has nothing the wearer
    /// needs to hear.
    public let announce: String?
    /// Set when a local file could not be read.
    public let localFailure: WearerTaskLocalFailure?
    /// How many things the tool found — transcript excerpts, memory entries — or `nil` when
    /// the tool does not count in items.
    ///
    /// Diagnostics only, and it is a count for the same reason every other field on that
    /// line is: the question lane's latency line has to be readable on hardware, and
    /// "answered in one call from four excerpts" is the whole measurement. The number never
    /// reaches the model — it reads ``text``, which already says how many excerpts it has.
    public let itemCount: Int?

    public init(
        text: String,
        announce: String? = nil,
        localFailure: WearerTaskLocalFailure? = nil,
        itemCount: Int? = nil
    ) {
        self.text = text
        self.announce = announce
        self.localFailure = localFailure
        self.itemCount = itemCount
    }

    /// A tool that worked.
    public static func ok(_ text: String, itemCount: Int? = nil) -> WearerTaskToolOutput {
        .init(text: text, itemCount: itemCount)
    }

    /// A tool that worked and did something the wearer must hear about.
    public static func announcing(_ text: String, say notice: String) -> WearerTaskToolOutput {
        .init(text: text, announce: notice)
    }

    /// A local file that would not answer. Loud, honest, and survivable.
    ///
    /// - Parameters:
    ///   - reason: the operator's short reason, for the error-level diagnostic.
    ///   - text: what the model is told, so it can be honest in its own words.
    ///   - notice: the sentence TapQ says if nothing better gets said.
    public static func localFailure(
        _ reason: String, tellingModel text: String, saying notice: String
    ) -> WearerTaskToolOutput {
        .init(
            text: text,
            localFailure: WearerTaskLocalFailure(reason: reason, wearerNotice: notice)
        )
    }
}

/// How an `ask_wearer` ended.
///
/// The three cases are the three a ``TapQContracts/Decision`` already has, and that is not a
/// coincidence: `ask_wearer` goes out through the runtime's existing question machinery, so
/// its answers are that machinery's answers. ``unanswered`` covers every way the wearer did
/// not say yes or no — the window timed out, they deferred to the screen, the prompt could
/// not be delivered — because from the loop's side those are one fact.
public enum WearerTaskWearerAnswer: Sendable, Equatable {
    case yes
    case no
    /// No answer inside the question machinery's own deadline
    /// (``TapQContracts/InteractionBudget/total``). The loop ends the task audibly on this;
    /// see ``WearerTaskLoop``.
    case unanswered
}

/// The tools, as closures the composition wires.
///
/// Closures rather than a protocol with seven methods for the reason every other seam on
/// this path is one: the real implementations live in three different targets and one
/// executable — the transcript store here, the roster and the mailbox in the CLI's
/// conversation memory, the approval machinery in the interaction baseline — and an engine
/// that named those types would drag the whole runtime into a portable target. The engine
/// knows seven verbs; it does not know what is behind any of them.
///
/// Every closure is `@MainActor` because every surface behind it already is. None of them
/// throws: a tool that failed says so in its ``WearerTaskToolOutput``, because a thrown
/// error inside the loop would be indistinguishable from the one thing that *must* break the
/// voice, which is a failed cloud call.
public struct WearerTaskSurfaces {
    /// Pillar A retrieval: TapQ's own dialogue with the wearer, older than the recent window.
    public var searchMemory: @MainActor (_ query: String) -> WearerTaskToolOutput
    /// Pillar B retrieval: excerpts from an agent's session history. Excerpts, not an answer
    /// — the loop's own model writes the answer, which is what lets one turn combine a
    /// transcript slice with something out of memory.
    public var readTranscript:
        @MainActor (_ agent: String?, _ query: String) -> WearerTaskToolOutput
    /// Roster, waits, and queues, from the surfaces `query_status` already answers out of.
    public var status: @MainActor () -> WearerTaskToolOutput
    /// The existing instruction path, rung E name resolution and fail-closed refusal
    /// included. The loop gets no authority the dictation flow does not have.
    public var queueInstruction:
        @MainActor (_ agent: String?, _ text: String) -> WearerTaskToolOutput
    /// The scripted-speech channel, verbatim.
    public var speak: @MainActor (_ text: String) -> Void
    /// The existing question machinery. It suspends until the wearer answers or the window's
    /// own deadline passes, which is what makes `ask_wearer` a pause the loop resumes from.
    public var askWearer: @MainActor (_ question: String) async -> WearerTaskWearerAnswer
    /// Records the task in Pillar A: the goal when it starts, the outcome when it ends. Only
    /// speech-cleared text — never a tool payload, never an excerpt.
    public var recordTask: @MainActor (_ goal: String, _ outcome: String) -> Void
    /// Registers a one-shot follow-up for an agent's next finished boundary
    /// (``WearerFollowupBook``). The task lane's ninth tool.
    ///
    /// It returns a ``WearerTaskToolOutput`` like every other tool, and it is expected to
    /// *announce*: what TapQ has agreed to do later, in the wearer's name, has to be audible
    /// at the moment it is agreed to, exactly as `queue_instruction` is. See
    /// ``WearerFollowupScheduler`` for the composition that does both.
    ///
    /// Defaulted to a refusal rather than left optional. The declaration cannot be gated per
    /// composition — the provider that sends the tool set reads only
    /// ``WearerTaskContract/tools(for:)``, and threading a flag through it would reach into
    /// a file this seam does not own — so the honest arrangement is a tool that is always
    /// declared and a surface that says plainly when nothing is behind it. The model reads
    /// that sentence and has `cannot_do` for what to do next. In practice the gate is moot:
    /// the loop is composed on exactly one arm, and that arm composes the book.
    public var setFollowup:
        @MainActor (_ agent: String?, _ instruction: String) -> WearerTaskToolOutput

    /// Starts a new agent session for the goal and moves the focus to it
    /// (`docs/SESSION_FOCUS_PLAN.md`). The task lane's tenth tool.
    ///
    /// `async` because it may ask the wearer first — the focused session is mid-task and
    /// the switch would walk away from it — through the same question machinery
    /// `askWearer` uses. Like `set_followup` it is expected to *announce*: the switch is
    /// loud once, at the moment it happens, and this output's `announce` is that sentence.
    /// Defaulted to a refusal for the reason `setFollowup` is: the declaration cannot be
    /// gated per composition, so a run with no launcher says plainly that nothing started.
    public var startSession: @MainActor (_ goal: String) async -> WearerTaskToolOutput

    /// What a composition with no follow-up book answers with.
    public nonisolated static let noFollowupBookText =
        "TapQ cannot set follow-ups in this run, so nothing was scheduled."

    /// What a composition with no session launcher answers with.
    public nonisolated static let noSessionLauncherText =
        "TapQ cannot start agent sessions in this run, so nothing was started. Tell the "
        + "wearer with cannot_do."

    public init(
        searchMemory: @escaping @MainActor (String) -> WearerTaskToolOutput,
        readTranscript: @escaping @MainActor (String?, String) -> WearerTaskToolOutput,
        status: @escaping @MainActor () -> WearerTaskToolOutput,
        queueInstruction: @escaping @MainActor (String?, String) -> WearerTaskToolOutput,
        speak: @escaping @MainActor (String) -> Void,
        askWearer: @escaping @MainActor (String) async -> WearerTaskWearerAnswer,
        recordTask: @escaping @MainActor (String, String) -> Void,
        setFollowup: @escaping @MainActor (String?, String) -> WearerTaskToolOutput = { _, _ in
            .ok(WearerTaskSurfaces.noFollowupBookText)
        },
        startSession: @escaping @MainActor (String) async -> WearerTaskToolOutput = { _ in
            .ok(WearerTaskSurfaces.noSessionLauncherText)
        }
    ) {
        self.searchMemory = searchMemory
        self.readTranscript = readTranscript
        self.status = status
        self.queueInstruction = queueInstruction
        self.speak = speak
        self.askWearer = askWearer
        self.recordTask = recordTask
        self.setFollowup = setFollowup
        self.startSession = startSession
    }
}
