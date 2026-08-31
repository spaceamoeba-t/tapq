import Foundation
import TapQContracts

/// Starts Claude Code sessions from nothing, and owns the ones it starts
/// (`docs/VOICE_ONLY_AGENT_PLAN.md` §7, leg 2 — the cord-style spawn-and-own borrowed in §3).
///
/// Leg 1 gave a session the wearer had already started the patience to sit in voice mode.
/// This is the other half: "new task: ⟨…⟩" with nothing running spawns a headless `claude`
/// whose hooks are TapQ's, whose session id TapQ chose, and whose later instructions and
/// approvals therefore have somewhere to land. It is the thing
/// ``TapQContextBaseline/WearerTaskDecision/cannotDo(spoken:)`` was added to refuse honestly
/// on 2026-08-30, when a goal of "start a new session in Claude Code" had nowhere to go.
///
/// **The id is chosen, not discovered.** `claude --session-id <uuid>` sets the conversation's
/// identifier (verified in the installed build's `--help`, 2026-08-31), so the mapping exists
/// before the process does: TapQ mints a lowercase UUID, spawns with it, and files the
/// session under it. Nothing has to be parsed out of stdout and nothing has to be correlated
/// after the fact. The hook traffic that arrives later *confirms* the mapping rather than
/// establishing it — and until some arrives, the spawn is not yet known to have worked. See
/// ``noteContact(sessionID:)`` and ``TapQContracts/OwnedSessionBudget/contactTimeout``.
///
/// **One at a time, on purpose.** `docs/FLEET_ROSTER_PLAN.md` rung E assumes at most one live
/// session per adapter, and a second Claude Code session makes the name "Claude" resolve to
/// neither — taking name-routing away from the session the wearer is already using. So this
/// spawns only into emptiness: the agent has no live session in the roster, and TapQ owns
/// none of its own. Both guards fail closed, out loud, and neither falls back to a guess.
///
/// **It never terminates a session it did not start.** The books here hold only spawned
/// children, and ``TapQClaudeAdapter/OwnedSessionProcessRunning`` is required to ignore any
/// identifier it did not launch, so the rule survives a bug in this type as well as its
/// absence.
@MainActor public final class OwnedClaudeSessionLauncher: OwnedSessionLaunching {
    /// What the composition decides about every spawn.
    public struct Configuration: Sendable {
        /// The agent CLI to resolve on `PATH`.
        public var executableName: String
        /// Where an owned session works. The composition's choice — TapQ does not infer a
        /// repository from a spoken goal.
        public var workingDirectoryPath: String
        /// The child's environment, passed through as given.
        ///
        /// It is the runtime's own environment and it has to be: the spawned session's hooks
        /// locate *this* broker through `TAPQ_BROKER_DIR`, and a filtered environment that
        /// dropped it would produce exactly the failure this launcher is most careful about —
        /// a session that runs and never reports in.
        public var environment: [String: String]
        /// Which settings sources the spawned session loads, or `nil` to pass no flag and
        /// take the CLI's own default.
        ///
        /// Explicit by default because TapQ's hooks live in `~/.claude/settings.json` and a
        /// session that did not load user settings would come up with no TapQ hooks at all —
        /// invisible, uninstructable, and only detectable by its silence. Naming the sources
        /// removes the question. `--setting-sources` exists in the installed build's `--help`
        /// (verified 2026-08-31); whether print mode would have loaded them anyway is not
        /// verified, and this is what makes it not matter.
        public var settingSources: [String]?
        /// How many sessions TapQ may own at once.
        ///
        /// One, under rung E's assumption. It is a constant with a name rather than an `if`
        /// because rung F's roster is the thing that raises it, and the guard that reads it
        /// should not have to be rewritten then.
        public var maximumOwnedSessions: Int

        public init(
            workingDirectoryPath: String,
            environment: [String: String],
            executableName: String = "claude",
            settingSources: [String]? = ["user", "project", "local"],
            maximumOwnedSessions: Int = 1
        ) {
            self.workingDirectoryPath = workingDirectoryPath
            self.environment = environment
            self.executableName = executableName
            self.settingSources = settingSources
            self.maximumOwnedSessions = maximumOwnedSessions
        }
    }

    private let configuration: Configuration
    private let processRunner: any OwnedSessionProcessRunning
    private let hookStatus: @Sendable () -> ClaudeHookInstallationStatus
    private let agentIsLive: LiveAgentSessionQuerying
    private let record: OwnedSessionRecording
    private let sessionIDFactory: @Sendable () -> String
    private let clock: @Sendable () -> Date
    private let diagnostics: TapQDiagnosticEmitter
    private let agent = AgentIdentity.claudeCode

    /// The sessions TapQ started, keyed by the id it chose for them, in spawn order.
    private var sessions: [OwnedSession] = []

    /// - Parameters:
    ///   - hookStatus: TapQ's hook registration as the installer reads it. Only
    ///     ``ClaudeHookInstallationStatus/notInstalled`` refuses: a partial or stale layout
    ///     still routes some traffic to the broker, and the contact timeout is the backstop
    ///     for the case where it turns out not to.
    ///   - agentIsLive: the rung E guard, reading the runtime's roster. `true` means the
    ///     wearer already has a Claude Code session and this one must not be started.
    ///   - record: writes the goal to the wearer's memory on spawn and the outcome on
    ///     ending, as a pair.
    ///   - sessionIDFactory: the chosen session id. Lowercase by default because Claude Code
    ///     writes session ids in lowercase on disk (verified against `~/.claude/projects`,
    ///     2026-08-31); matching is case-insensitive anyway, so a build that normalized
    ///     differently would still correlate.
    public init(
        configuration: Configuration,
        processRunner: any OwnedSessionProcessRunning,
        hookStatus: @escaping @Sendable () -> ClaudeHookInstallationStatus,
        agentIsLive: @escaping LiveAgentSessionQuerying,
        record: @escaping OwnedSessionRecording = { _, _ in },
        sessionIDFactory: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        clock: @escaping @Sendable () -> Date = { Date() },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
        self.hookStatus = hookStatus
        self.agentIsLive = agentIsLive
        self.record = record
        self.sessionIDFactory = sessionIDFactory
        self.clock = clock
        self.diagnostics = TapQDiagnosticEmitter(
            category: "OwnedClaudeSession", sink: diagnosticSink
        )
    }

    // MARK: - Launching

    public var ownedSessions: [OwnedSession] { sessions }

    public func launchOwnedSession(goal: String) -> OwnedSessionLaunch {
        // Children that have already exited are dropped first, so a finished session never
        // blocks the next one. Their endings are recorded and logged but not spoken: the
        // wearer is in the middle of asking for something new, and a notice about a session
        // that is already over would arrive on top of the answer to what they just said.
        // The composition's ``sweep(now:)`` is where those notices normally come from.
        discardEndedSessions(now: clock())

        guard let prompt = Self.promptText(from: goal) else {
            return refuse(.emptyGoal, goal: goal)
        }
        guard sessions.count < configuration.maximumOwnedSessions else {
            return refuse(.alreadyOwnsSession(agentDisplayName: agent.displayName), goal: goal)
        }
        guard !agentIsLive() else {
            return refuse(.agentAlreadyLive(agentDisplayName: agent.displayName), goal: goal)
        }
        guard hookStatus() != .notInstalled else {
            return refuse(
                .integrationNotInstalled(agentDisplayName: agent.displayName), goal: goal
            )
        }
        guard Self.isUsableDirectory(configuration.workingDirectoryPath) else {
            return refuse(.workingDirectoryUnusable, goal: goal)
        }
        guard let executablePath = POSIXOwnedSessionProcessRunner.resolveExecutable(
            named: configuration.executableName,
            environment: configuration.environment,
            workingDirectoryPath: configuration.workingDirectoryPath
        ) else {
            return refuse(
                .agentExecutableNotFound(agentDisplayName: agent.displayName), goal: goal
            )
        }

        let sessionID = sessionIDFactory()
        let spawn = OwnedSessionSpawn(
            executablePath: executablePath,
            arguments: Self.spawnArguments(
                sessionID: sessionID,
                prompt: prompt,
                settingSources: configuration.settingSources
            ),
            environment: configuration.environment,
            workingDirectoryPath: configuration.workingDirectoryPath
        )

        guard case .launched(let processIdentifier) = processRunner.launch(spawn) else {
            return refuse(.spawnFailed(agentDisplayName: agent.displayName), goal: goal)
        }

        let session = OwnedSession(
            sessionID: sessionID,
            agent: agent,
            processIdentifier: processIdentifier,
            goal: goal,
            startedAt: clock()
        )
        sessions.append(session)
        diagnostics.record("launched", fields: [
            "session": sessionID,
            "pid": "\(processIdentifier)",
        ])
        // Recorded at the start, with the ending written when there is one. A runtime that
        // dies in between leaves "started" with no ending, which is the honest record: the
        // session is gone, the wearer's request is not.
        record(goal, "started")
        return .started(session)
    }

    private func refuse(_ refusal: OwnedSessionRefusal, goal: String) -> OwnedSessionLaunch {
        diagnostics.record("refused", level: .warning, fields: [
            "reason": refusal.recordedOutcome,
        ])
        record(goal, refusal.recordedOutcome)
        return .refused(refusal)
    }

    // MARK: - The mapping

    /// Confirms that the session TapQ started has reached the broker.
    ///
    /// Called from wherever the runtime already observes hook traffic — the same place the
    /// roster's `noteAgentSeen` is called — rather than from a subscription of its own, for
    /// the reason that roster gives: two observers of the same traffic are two things that
    /// can disagree about who is alive.
    ///
    /// Traffic from a session TapQ did not start is not an error and is not interesting here;
    /// it is a keyboard session, and this returns `false` and does nothing. Matching is
    /// case-insensitive so a build that normalized the chosen UUID's case would still
    /// correlate.
    ///
    /// - Returns: whether the id belonged to a session TapQ owns.
    @discardableResult
    public func noteContact(sessionID: String) -> Bool {
        guard let index = indexOfSession(id: sessionID) else { return false }
        guard !sessions[index].hasReportedIn else { return true }
        let existing = sessions[index]
        sessions[index] = OwnedSession(
            sessionID: existing.sessionID,
            agent: existing.agent,
            processIdentifier: existing.processIdentifier,
            goal: existing.goal,
            startedAt: existing.startedAt,
            contactedAt: clock()
        )
        diagnostics.record("reported_in", fields: ["session": existing.sessionID])
        return true
    }

    /// Whether `sessionID` names a session TapQ started. The query the integrator binds
    /// instructions and approvals with, and guards a second spawn on.
    public func owns(sessionID: String) -> Bool { indexOfSession(id: sessionID) != nil }

    private func indexOfSession(id: String) -> Int? {
        sessions.firstIndex { $0.sessionID.caseInsensitiveCompare(id) == .orderedSame }
    }

    // MARK: - Lifecycle

    /// Looks at every owned child and closes the ones that are over.
    ///
    /// Driven by the composition on ``TapQContracts/OwnedSessionBudget/sweepInterval``. Two
    /// endings need TapQ to act and the caller to speak: a child that exited without ever
    /// reporting in, and one still running that has not reported in inside the contact
    /// timeout. Both mean the spawn did not become a session TapQ can see, and the second is
    /// the one the child is killed for — a session working on the wearer's goal where the
    /// wearer cannot instruct it, interrupt it, or answer for it is worse than none.
    ///
    /// - Returns: the sessions that ended, with their endings, oldest first.
    @discardableResult
    public func sweep(now: Date) -> [OwnedSessionClosure] {
        var closures: [OwnedSessionClosure] = []
        var survivors: [OwnedSession] = []
        for session in sessions {
            guard let ending = Self.ending(for: session, now: now, runner: processRunner) else {
                survivors.append(session)
                continue
            }
            closures.append(OwnedSessionClosure(session: session, ending: ending))
        }
        sessions = survivors
        for closure in closures { close(closure) }
        return closures
    }

    /// Stops every session TapQ owns, and only those.
    ///
    /// Called from the runtime's shutdown path. A keyboard-started session is untouched here
    /// by construction: it was never in these books, and the runner would ignore it anyway.
    @discardableResult
    public func shutdown() -> [OwnedSessionClosure] {
        let closures = sessions.map {
            OwnedSessionClosure(session: $0, ending: .terminatedOnShutdown)
        }
        sessions = []
        for closure in closures { close(closure) }
        return closures
    }

    /// Terminates where the ending calls for it, records the outcome, and logs.
    private func close(_ closure: OwnedSessionClosure) {
        if closure.ending.requiresTermination {
            processRunner.terminate(processIdentifier: closure.session.processIdentifier)
        }
        diagnostics.record(
            "ended",
            level: closure.ending.spoken == nil ? .info : .warning,
            fields: [
                "session": closure.session.sessionID,
                "ending": closure.ending.recordedOutcome,
            ]
        )
        record(closure.session.goal, closure.ending.recordedOutcome)
    }

    /// Drops sessions whose process is gone, without speaking about them. The launch path's
    /// pruning; ``sweep(now:)`` is the one that hands the endings back.
    private func discardEndedSessions(now: Date) {
        var survivors: [OwnedSession] = []
        var closures: [OwnedSessionClosure] = []
        for session in sessions {
            if processRunner.isRunning(processIdentifier: session.processIdentifier) {
                survivors.append(session)
            } else {
                closures.append(OwnedSessionClosure(
                    session: session,
                    ending: session.hasReportedIn ? .exited : .exitedBeforeContact
                ))
            }
        }
        sessions = survivors
        for closure in closures { close(closure) }
    }

    /// How an owned session ended, or `nil` while it has not.
    private static func ending(
        for session: OwnedSession,
        now: Date,
        runner: any OwnedSessionProcessRunning
    ) -> OwnedSessionEnding? {
        guard runner.isRunning(processIdentifier: session.processIdentifier) else {
            return session.hasReportedIn ? .exited : .exitedBeforeContact
        }
        guard !session.hasReportedIn else { return nil }
        guard now.timeIntervalSince(session.startedAt) >= OwnedSessionBudget.contactTimeout else {
            return nil
        }
        return .contactTimedOut
    }

    // MARK: - The argument vector

    /// The whole of what TapQ asks the agent to do, in order.
    ///
    /// Verified against the installed Claude Code build's `--help` (2.1.153, 2026-08-31):
    /// `-p, --print` runs non-interactively, `--session-id <uuid>` fixes the conversation's
    /// identifier, `--setting-sources` names which settings files load, and the prompt is a
    /// positional argument.
    ///
    /// What is deliberately *not* here is as much of the design as what is. No
    /// `--permission-mode`: the wearer's own settings decide, and TapQ's `PreToolUse` hook
    /// answers within whatever they chose. No `--dangerously-skip-permissions` and no
    /// `--allowedTools`: a session TapQ started must ask for exactly what a session the
    /// wearer started asks for, or the spoken approval loop is a formality over an agent that
    /// was never going to stop. And no output format: an owned session speaks to TapQ through
    /// the broker, not through its stdout.
    static func spawnArguments(
        sessionID: String,
        prompt: String,
        settingSources: [String]?
    ) -> [String] {
        var arguments = ["--print", "--session-id", sessionID]
        if let settingSources, !settingSources.isEmpty {
            arguments += ["--setting-sources", settingSources.joined(separator: ",")]
        }
        arguments.append(prompt)
        return arguments
    }

    /// The wearer's goal in the shape an argument vector can carry, or `nil` when nothing is
    /// left of it.
    ///
    /// Three rules, and only the third is a judgement call. Whitespace — including the
    /// newlines a recognizer never produces but a caller might — collapses to single spaces,
    /// and control characters are dropped, so the prompt is one line of text. Length is
    /// bounded by ``TapQContracts/OwnedSessionBudget/maximumGoalCharacters``, which a spoken
    /// sentence never approaches and a recognizer that failed to endpoint would sail past.
    ///
    /// And leading hyphens are stripped: a goal beginning with one would be read by the CLI
    /// as a flag rather than as the prompt, which is the one way a transcript could reach
    /// past the argument it is supposed to be. Spoken goals do not begin with hyphens, so the
    /// rule costs nothing real and closes the hole rather than trusting the parser to.
    static func promptText(from goal: String) -> String? {
        var collapsed = ""
        var pendingSeparator = false
        for character in goal {
            if character.isWhitespace {
                pendingSeparator = !collapsed.isEmpty
                continue
            }
            if character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                continue
            }
            if pendingSeparator {
                collapsed.append(" ")
                pendingSeparator = false
            }
            collapsed.append(character)
        }
        let unflagged = collapsed.drop(while: { $0 == "-" })
            .trimmingCharacters(in: .whitespaces)
        guard !unflagged.isEmpty else { return nil }
        guard unflagged.count > OwnedSessionBudget.maximumGoalCharacters else { return unflagged }
        return String(unflagged.prefix(OwnedSessionBudget.maximumGoalCharacters))
    }

    private static func isUsableDirectory(_ path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
