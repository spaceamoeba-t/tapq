import Foundation

/// One headless agent session TapQ started, and is therefore responsible for
/// (`docs/VOICE_ONLY_AGENT_PLAN.md` §7, leg 2).
///
/// The distinction this type exists to draw is ownership. Leg 1 made a session the wearer
/// started at the keyboard hold its turn boundary open; leg 2 lets TapQ start one from
/// nothing. Those two are the same session to the broker and must never be the same session
/// to the launcher: TapQ may terminate a session it spawned, and must never terminate one a
/// person is sitting in front of. Everything downstream of that rule reads this record.
///
/// Speech-safe by construction, like every other store on this path. The goal is the
/// wearer's own sentence — already read back to them out loud — and the remaining fields are
/// an opaque session key, a pid, an identity TapQ says by name, and two timestamps. There is
/// nowhere to put a `cwd`, a tool payload, or anything the agent has since produced.
public struct OwnedSession: Sendable, Equatable {
    /// The session key TapQ chose *before* the process started, and the whole of the
    /// cord-style mapping: later instructions and approvals for this conversation carry it.
    public let sessionID: String
    /// The adapter behind it. Carried rather than assumed, so a second owned-session
    /// launcher for another agent reads the same record.
    public let agent: AgentIdentity
    /// The child TapQ launched. Only ever used to stop a session TapQ started.
    public let processIdentifier: Int32
    /// The wearer's sentence, verbatim, as the realtime model reported it.
    public let goal: String
    /// When the spawn returned.
    public let startedAt: Date
    /// When the session's hooks first reached the broker, or `nil` while TapQ has still
    /// never heard from the process it started.
    ///
    /// This is the only evidence that a spawn *worked*. A `claude` that launched but whose
    /// hooks do not reach this broker is a session TapQ cannot see, cannot instruct, and
    /// cannot answer approvals for — indistinguishable, from the wearer's side, from one
    /// that never started. See ``OwnedSessionEnding/contactTimedOut``.
    public let contactedAt: Date?

    public init(
        sessionID: String,
        agent: AgentIdentity,
        processIdentifier: Int32,
        goal: String,
        startedAt: Date,
        contactedAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.processIdentifier = processIdentifier
        self.goal = goal
        self.startedAt = startedAt
        self.contactedAt = contactedAt
    }

    /// Whether the spawned session's hooks have ever reached the broker.
    public var hasReportedIn: Bool { contactedAt != nil }
}

/// Why nothing was spawned.
///
/// Every case is fail-closed and every case can be spoken: a wearer who cannot see a screen
/// learns that TapQ did *not* start anything, and why, in one sentence. The alternative —
/// refusing quietly — is the failure this rung was written against, where the wearer waits
/// for work that was never going to happen.
public enum OwnedSessionRefusal: Sendable, Equatable {
    /// TapQ is still winding down sessions it started — every slot in
    /// ``OwnedSessionBudget/maximumOwnedSessions`` is taken by a child that has been
    /// detached and has not yet exited. Not a guard against a second session: under
    /// session focus (`docs/SESSION_FOCUS_PLAN.md`) starting one while another runs is the
    /// feature, and the old one is detached and wound down. This is only the bound on how
    /// many children can be winding down at once, and it clears within a sweep.
    case stillWindingDown(agentDisplayName: String)
    /// The wearer's goal was empty once the transcript was cleaned up.
    case emptyGoal
    /// TapQ's hooks are not registered with the agent, so a session started now would be one
    /// TapQ could never see. Refused before spawning rather than spawned and killed later:
    /// the remedy is an install, and the wearer should hear that before any work happens.
    case integrationNotInstalled(agentDisplayName: String)
    /// No `claude` on `PATH`.
    case agentExecutableNotFound(agentDisplayName: String)
    /// The working directory the composition supplied is not a directory TapQ can start a
    /// session in.
    case workingDirectoryUnusable
    /// TapQ had no folder to use and could not make one either: the workspace root, the
    /// session folder under it, or the hook settings inside it could not be written
    /// (`docs/WAKE_WORD_PLAN.md` §5).
    ///
    /// Separate from ``workingDirectoryUnusable`` because the two are different facts about
    /// the same missing folder, and the wearer can act on the difference: one is a directory
    /// they named that does not work, the other is TapQ failing at the one place it writes
    /// under their home. A run that heard "I don't have a folder to start that in" would go
    /// looking for the folder it gave TapQ, and there isn't one.
    case workspaceUnwritable
    /// The process would not start.
    case spawnFailed(agentDisplayName: String)

    /// The sentence the wearer hears. One line, the remedy where there is one, in the
    /// register of the shipped refusals (`InteractionController.ambiguousAgentRefusal`,
    /// `WearerTaskLoop.busyNotice`).
    public var spoken: String {
        switch self {
        case .stillWindingDown(let agent):
            return "I'm still winding down the last \(agent) session I started — "
                + "say it again in a moment."
        case .emptyGoal:
            return "I didn't catch that — say it again."
        case .integrationNotInstalled(let agent):
            return "I can't start \(agent) until its TapQ hooks are installed."
        case .agentExecutableNotFound(let agent):
            return "I couldn't find \(agent) on this machine."
        case .workingDirectoryUnusable:
            return "I don't have a folder to start that in."
        case .workspaceUnwritable:
            return "I couldn't make a folder to start that in."
        case .spawnFailed(let agent):
            return "\(agent) wouldn't start — nothing is running."
        }
    }

    /// The short reason written to the wearer's memory and to diagnostics. Never the goal,
    /// never a path: those are the caller's to record.
    public var recordedOutcome: String {
        switch self {
        case .stillWindingDown: return "refused: still winding down"
        case .emptyGoal: return "refused: empty goal"
        case .integrationNotInstalled: return "refused: hooks not installed"
        case .agentExecutableNotFound: return "refused: agent not found"
        case .workingDirectoryUnusable: return "refused: no working directory"
        case .workspaceUnwritable: return "refused: workspace unwritable"
        case .spawnFailed: return "refused: spawn failed"
        }
    }
}

/// What one launch attempt did. There is no third answer: a session is running under a known
/// id, or nothing was started and the wearer is told why.
public enum OwnedSessionLaunch: Sendable, Equatable {
    case started(OwnedSession)
    case refused(OwnedSessionRefusal)
}

/// Why a session stopped being one TapQ owns.
///
/// Ownership ends for five reasons and they are not interchangeable — two are failures the
/// wearer must hear about, two are the ordinary end of a headless run, and one is the
/// wearer having moved on.
public enum OwnedSessionEnding: Sendable, Equatable {
    /// The process exited before its hooks ever reached the broker. The fast, exact form of
    /// ``contactTimedOut``: bad flags, a build that rejects `--session-id`, an unauthenticated
    /// CLI. Noticed within one sweep rather than one timeout.
    case exitedBeforeContact
    /// The process is still running but has never reached the broker inside
    /// ``OwnedSessionBudget/contactTimeout``. The child is killed, because a session TapQ
    /// started, cannot see, and cannot answer approvals for is worse than no session: it
    /// holds the wearer's goal somewhere they cannot reach it.
    case contactTimedOut
    /// The session ran, was seen, and the process has now exited. The ordinary end of a
    /// headless run.
    case exited
    /// TapQ is going away and took its own children with it.
    case terminatedOnShutdown
    /// The wearer moved TapQ's focus to another session (`docs/SESSION_FOCUS_PLAN.md`).
    /// A session TapQ started has no terminal to go back to, so it is wound down: its
    /// pending approvals are denied, it is given ``OwnedSessionBudget/detachGrace`` to
    /// finish its turn and exit, and it is killed if it does not.
    case detached

    /// The sentence the wearer hears, or `nil` where nothing needs saying.
    ///
    /// `nil` for the endings that are not failures. A run that finished has already
    /// announced itself through the ordinary Stop path, a shutdown has taken the speech
    /// channel away with it — the same reasoning `WearerTaskLoop.cancel` records silently —
    /// and a detach was announced once, at the switch, by the composition that moved the
    /// focus; a second sentence when the process finally exits would speak for a session
    /// the wearer has already been told is gone.
    public var spoken: String? {
        switch self {
        case .exitedBeforeContact, .contactTimedOut:
            return "The session I started never reported in, so I've stopped it."
        case .exited, .terminatedOnShutdown, .detached:
            return nil
        }
    }

    /// The outcome written to the wearer's memory, paired with the `"started"` recorded when
    /// the session was spawned.
    public var recordedOutcome: String {
        switch self {
        case .exitedBeforeContact: return "exited before reporting in"
        case .contactTimedOut: return "never reported in"
        case .exited: return "session ended"
        case .terminatedOnShutdown: return "stopped at shutdown"
        case .detached: return "detached: stopped"
        }
    }

    /// Whether TapQ has to stop the process itself. `false` for an ending the process
    /// reached on its own.
    public var requiresTermination: Bool {
        switch self {
        case .contactTimedOut, .terminatedOnShutdown, .detached: return true
        case .exitedBeforeContact, .exited: return false
        }
    }
}

/// One owned session's ending, as the composition reads it back out of a sweep.
public struct OwnedSessionClosure: Sendable, Equatable {
    public let session: OwnedSession
    public let ending: OwnedSessionEnding

    public init(session: OwnedSession, ending: OwnedSessionEnding) {
        self.session = session
        self.ending = ending
    }
}

/// Writes one line of the wearer's own memory: the goal when a session starts, the outcome
/// when it ends.
///
/// Shaped to `WearerConversationStore.recordTask(goal:outcome:)` because it is the same
/// record and should not become a second one — the pair of calls is what leaves an honest
/// trace when the runtime dies in between ("TapQ started a Claude Code session for ⟨goal⟩"
/// with no ending is exactly true).
public typealias OwnedSessionRecording = @MainActor (_ goal: String, _ outcome: String) -> Void

/// Where the next owned session should work, or `nil` when TapQ has nowhere to start one.
///
/// Answered per launch rather than fixed at composition, because the answer moves with
/// the focus (`docs/SESSION_FOCUS_PLAN.md` §6): the focused session's directory when there
/// is one, else the operator's configured default. Never inferred from the spoken goal.
public typealias OwnedSessionWorkingDirectory = @MainActor () -> String?

/// The seam the voice surface holds (`docs/VOICE_ONLY_AGENT_PLAN.md` §7, leg 2).
///
/// Deliberately the same shape as ``WearerTaskStarting``: one verb that takes a goal and
/// answers with something to say, plus the one query a caller needs to know whether it
/// should be calling at all. A voice layer holding this can start a session and can find out
/// which session it started. It cannot terminate one, cannot read its output, and cannot
/// reach the process — those are the composition's, and they stay off this protocol so that
/// nothing on the voice path acquires them by holding it.
public protocol OwnedSessionLaunching: Sendable {
    /// Starts a headless session for `goal`, or refuses with a sentence the caller speaks
    /// verbatim.
    @MainActor func launchOwnedSession(goal: String) -> OwnedSessionLaunch

    /// The sessions TapQ started and still owns, oldest first.
    ///
    /// The cord-style mapping, read back: "the session I spawned is session X". The
    /// integrator binds later instructions and approvals to these ids, and checks this
    /// before offering to start anything else.
    @MainActor var ownedSessions: [OwnedSession] { get }
}
