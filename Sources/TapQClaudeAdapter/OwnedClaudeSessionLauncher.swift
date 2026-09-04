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
/// **Newest wins, and the old one is wound down.** As first built this spawned only into
/// emptiness — no live session in the roster, none owned — because rung E's roster made a
/// second session of one adapter ambiguous. Session focus (`docs/SESSION_FOCUS_PLAN.md`)
/// replaced that: the composition starts the new session first, moves the focus to it, and
/// then ``detach(sessionID:)`` is called on the one that had it. A detached owned session
/// has no terminal to go back to, so it is wound down — its approvals are denied by the
/// composition, it gets ``TapQContracts/OwnedSessionBudget/detachGrace`` to finish and
/// exit, and the sweep kills it if it does not. The only guard left here is the bound on
/// how many children may be winding down at once.
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
        /// How many sessions TapQ may own at once, focused and winding down together. See
        /// ``TapQContracts/OwnedSessionBudget/maximumOwnedSessions``.
        public var maximumOwnedSessions: Int

        public init(
            environment: [String: String],
            executableName: String = "claude",
            settingSources: [String]? = ["user", "project", "local"],
            maximumOwnedSessions: Int = OwnedSessionBudget.maximumOwnedSessions
        ) {
            self.environment = environment
            self.executableName = executableName
            self.settingSources = settingSources
            self.maximumOwnedSessions = maximumOwnedSessions
        }
    }

    private let configuration: Configuration
    private let processRunner: any OwnedSessionProcessRunning
    private let hookStatus: @Sendable () -> ClaudeHookInstallationStatus
    private let workingDirectory: OwnedSessionWorkingDirectory
    private let record: OwnedSessionRecording
    private let sessionIDFactory: @Sendable () -> String
    private let clock: @Sendable () -> Date
    private let diagnostics: TapQDiagnosticEmitter
    private let agent = AgentIdentity.claudeCode

    /// The sessions TapQ started, keyed by the id it chose for them, in spawn order.
    private var sessions: [OwnedSession] = []
    /// When each detached session was detached, by session id. A session in here is
    /// winding down: it is killed by the sweep once its grace is up.
    private var detachedAt: [String: Date] = [:]

    /// Called for every ending, however it was reached — a sweep, a shutdown, or the
    /// silent pruning at the head of a launch. The composition frees the focus the
    /// session held, writes the session book, and speaks the endings that have a sentence.
    /// One hook rather than three return values, so no ending can go unobserved.
    public var onClosed: (@MainActor (OwnedSessionClosure) -> Void)?

    /// - Parameters:
    ///   - hookStatus: TapQ's hook registration as the installer reads it. Only
    ///     ``ClaudeHookInstallationStatus/notInstalled`` refuses: a partial or stale layout
    ///     still routes some traffic to the broker, and the contact timeout is the backstop
    ///     for the case where it turns out not to.
    ///   - workingDirectory: where the next session works, answered per launch — the
    ///     focused session's directory, else the configured default, else `nil` and the
    ///     launch is refused. Never inferred from the goal.
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
        workingDirectory: @escaping OwnedSessionWorkingDirectory,
        record: @escaping OwnedSessionRecording = { _, _ in },
        sessionIDFactory: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        clock: @escaping @Sendable () -> Date = { Date() },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
        self.hookStatus = hookStatus
        self.workingDirectory = workingDirectory
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
            return refuse(.stillWindingDown(agentDisplayName: agent.displayName), goal: goal)
        }
        guard hookStatus() != .notInstalled else {
            return refuse(
                .integrationNotInstalled(agentDisplayName: agent.displayName), goal: goal
            )
        }
        guard let workingDirectoryPath = workingDirectory(),
              Self.isUsableDirectory(workingDirectoryPath)
        else {
            return refuse(.workingDirectoryUnusable, goal: goal)
        }
        guard let executablePath = POSIXOwnedSessionProcessRunner.resolveExecutable(
            named: configuration.executableName,
            environment: configuration.environment,
            workingDirectoryPath: workingDirectoryPath
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
            environment: configuration.environment.merging(
                [Self.ownedSessionEnvironmentKey: "1"], uniquingKeysWith: { _, owned in owned }
            ),
            workingDirectoryPath: workingDirectoryPath
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
    /// instructions and approvals with.
    public func owns(sessionID: String) -> Bool { indexOfSession(id: sessionID) != nil }

    /// The owned sessions that still have a claim on the wearer: started and not detached.
    /// Diagnostics and tests; the roster, not this, says which session has the focus.
    public var activeSessions: [OwnedSession] {
        sessions.filter { detachedAt[$0.sessionID] == nil }
    }

    // MARK: - Detaching

    /// The focus moved away from a session TapQ started, so it is wound down
    /// (`docs/SESSION_FOCUS_PLAN.md` §3, step 7).
    ///
    /// Nothing is signalled here. The composition has already denied the session's pending
    /// approvals, so an agent mid-tool-call stops at its next hook; what it is given is
    /// ``TapQContracts/OwnedSessionBudget/detachGrace`` to finish its turn and exit on its
    /// own, and the next ``sweep(now:)`` after that kills whatever is still running. A
    /// session TapQ did not start, or one already detached, is untouched and `false`.
    ///
    /// - Returns: whether the id named an owned session that was not yet detached.
    @discardableResult
    public func detach(sessionID: String, now: Date) -> Bool {
        guard let index = indexOfSession(id: sessionID) else { return false }
        let session = sessions[index]
        guard detachedAt[session.sessionID] == nil else { return false }
        detachedAt[session.sessionID] = now
        diagnostics.record("detached", fields: [
            "session": session.sessionID,
            "grace_s": "\(Int(OwnedSessionBudget.detachGrace))",
        ])
        return true
    }

    /// Whether the session TapQ started has been detached and is winding down. The
    /// composition's approval handler reads it: a detached owned session's approvals are
    /// denied, not deferred to a screen it does not have.
    public func isDetached(sessionID: String) -> Bool {
        guard let index = indexOfSession(id: sessionID) else { return false }
        return detachedAt[sessions[index].sessionID] != nil
    }

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
    /// wearer cannot instruct it, interrupt it, or answer for it is worse than none. A
    /// third ending acts in silence: a detached child still running past its grace is
    /// killed, and nothing is said because the switch already was.
    ///
    /// - Returns: the sessions that ended, with their endings, oldest first.
    @discardableResult
    public func sweep(now: Date) -> [OwnedSessionClosure] {
        var closures: [OwnedSessionClosure] = []
        var survivors: [OwnedSession] = []
        for session in sessions {
            guard let ending = ending(for: session, now: now) else {
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
        detachedAt.removeValue(forKey: closure.session.sessionID)
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
        onClosed?(closure)
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
    private func ending(for session: OwnedSession, now: Date) -> OwnedSessionEnding? {
        guard processRunner.isRunning(processIdentifier: session.processIdentifier) else {
            return session.hasReportedIn ? .exited : .exitedBeforeContact
        }
        if let detached = detachedAt[session.sessionID] {
            // A detached child that reported in is judged only by its grace; one that never
            // reported in is judged by whichever of the two clocks runs out first.
            if now.timeIntervalSince(detached) >= OwnedSessionBudget.detachGrace {
                return .detached
            }
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
    /// `--permission-mode bypassPermissions` is the maintainer's decision of 2026-09-04,
    /// reversing the original one. The first shape carried no permission override, so a
    /// session TapQ started asked for exactly what a keyboard session asks for; on hardware
    /// that was four spoken "Approve?" rounds for one script, one of them lost, and under
    /// `--print` no dialog can be shown at all, so a tool Claude Code would have asked
    /// about is refused outright ("This command requires approval"). The session now runs
    /// everything it decides to run. TapQ's strict `PreToolUse` hook still fires and the
    /// broker allows silently, so every tool call is still on record; the Stop hook still
    /// forwards every reply because the session is marked owned (`TAPQ_OWNED_SESSION`),
    /// which lifts the shim's opt-out for this mode. No `--allowedTools` and no output
    /// format: an owned session speaks to TapQ through the broker, not through its stdout.
    static let permissionMode = "bypassPermissions"

    /// The variable an owned session's hooks read to know the session exists only to
    /// talk to the wearer. Set to `"1"` on the child's environment.
    public nonisolated static let ownedSessionEnvironmentKey = "TAPQ_OWNED_SESSION"

    static func spawnArguments(
        sessionID: String,
        prompt: String,
        settingSources: [String]?
    ) -> [String] {
        var arguments = ["--print", "--session-id", sessionID,
                         "--permission-mode", permissionMode]
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
