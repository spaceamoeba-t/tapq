import Foundation

/// One agent as the kernel sees it.
struct AgentState: Equatable {
    var phase: AgentPhase
    /// From `session.json`; nil = never started. Always nil for a chat in the user's app, which never
    /// resumes (2026-10-13).
    var sessionID: String?
    /// FIFO; the head is `pending.first`, and only the head is spoken or resolved.
    var pending: [PendingRequest] = []
    /// The last finished text, any length: what "read it all" reads.
    var heldReply: HeldReply?
    /// The last tool line, for the status channel (a host shows it); never spoken.
    var progress: String?
    /// The agent's id for the step `progress` names; nil when it gave that step none.
    var progressStep: String?
    /// The turn under way as TapQ saw it, for a spoken status (2026-10-15); in memory only.
    var turn: TurnSoFar?
    /// Counts the turns `turn` was made for, so a status summary of an earlier one is dropped.
    var turnNumber = 0
    /// The steers of the turn that just ended, for a turn the agent starts next on its own: a
    /// steer that crossed the end runs as a new turn (Codex resends it; Claude Code queues it).
    var carriedAsks: [String] = []
    /// The turn the journal shows open, as `Reconcile` folds it: a start with words opens one
    /// (a switch's yes, or a start without one since 2026-10-24), a `sent` delivers words to
    /// it, and a terminal event or a `lost` closes it.
    var openTurn: OpenTurn?
    /// Its process resumed a conversation and has sent no event since: one that ends now may
    /// have found the conversation gone (2026-10-12).
    var resumeUnproven = false
    /// Its last failure while TapQ ran on, as said, for the status channel: until it starts
    /// again or the user says no to starting it. In memory only.
    var failure: StatusReport.Failure?

    var head: PendingRequest? { pending.first }

    /// Where the step `progress` names is, as the agent reported it (2026-10-19): nil while
    /// there is no line, or the agent gave the step no id, so nothing can tell.
    var progressState: TurnSoFar.State? {
        guard progress != nil, let id = progressStep else { return nil }
        return turn?.steps.last { $0.id == id }?.state
    }
}

enum OpenTurn: Equatable { case launched, delivered }

/// How one agent failed while TapQ runs on (maintainer ruling 2026-10-12): each is told in
/// its own words, since the user's next move differs.
enum AgentFailure: Equatable {
    /// Its process ended on its own.
    case exited
    /// It broke the delegate contract, or TapQ could not reach it: TapQ stopped it.
    case lostTrack
    /// It never got going after the user's yes; the reason says why.
    case startFailed(String)

    var kind: StatusReport.Failure.Kind {
        switch self {
        case .exited: return .exited
        case .lostTrack: return .lostTrack
        case .startFailed: return .startFailed
        }
    }
}

struct HeldReply: Equatable {
    /// The `finished` record's seq; a summary is relayed only for the reply still held.
    let seq: Int
    let text: String
}

/// What a start opens, and how (2026-10-12: also a switch to another conversation, or a new
/// one): asked for a switch, made at once otherwise (2026-10-24).
struct Launch: Equatable {
    let folder: String
    let target: LaunchTarget
    /// Sent once the agent runs; empty for a switch with nothing to say, which opens no turn.
    let held: String
    /// The agent's process runs while the prompt waits (a switch asked of an idle agent): a no
    /// leaves it as it was, a yes stops it before the other conversation starts.
    let running: Bool
    /// The chosen conversation's number and name as read.
    var number: Int?
    var title: String?

    init(folder: String, target: LaunchTarget = .saved, held: String, running: Bool = false,
         number: Int? = nil, title: String? = nil) {
        self.folder = folder
        self.target = target
        self.held = held
        self.running = running
        self.number = number
        self.title = title
    }
}

/// An agent's conversations as last listed, newest first, and those read out so far.
struct ConversationList: Equatable {
    struct Read: Equatable {
        /// As read: the position in `sessions`, from 1.
        let number: Int
        let id: String
        let title: String
        let age: String
    }

    let sessions: [SessionSummary]
    var read: [Read] = []

    var unread: Int { sessions.count - read.count }
}

/// Something the user must say yes, no or an answer to.
struct PendingRequest: Equatable {
    enum Kind: Equatable {
        case launch(Launch)
        case permission(PermissionRequest)
        case question(QuestionRequest)
    }

    let id: String
    let kind: Kind
    /// Exactly the sentence TapQ speaks for it. A shell command's is the command read whole
    /// until its description replaces it.
    var prompt: String
    /// A shell command's description is still on its way, so the prompt is not asked yet.
    var describing = false
    /// The speech reading the prompt now or last; nil once a re-ask is queued.
    var promptID: SpeechID?
    /// Some reading of the prompt has started, so a withdrawal must be told.
    var spoken = false
    /// Set only by a verbatim playback of `promptID`: gate condition (b).
    var promptPlayedAt: TimeInterval?
    /// Non-verbatim playbacks so far; the second resolves the request as a refusal.
    var misreadings = 0

    var summary: PendingSummary {
        switch kind {
        case .launch:
            return PendingSummary(kind: .launch, requestID: id, prompt: prompt, canAlwaysAllow: false,
                                  heard: promptPlayedAt != nil)
        case .permission(let request):
            return PendingSummary(kind: .permission, requestID: id, prompt: prompt,
                                  canAlwaysAllow: request.alwaysAllow != nil, heard: promptPlayedAt != nil)
        case .question(let request):
            return PendingSummary(kind: .question, requestID: id, prompt: prompt,
                                  questions: request.questions, canAlwaysAllow: false, heard: promptPlayedAt != nil)
        }
    }
}
