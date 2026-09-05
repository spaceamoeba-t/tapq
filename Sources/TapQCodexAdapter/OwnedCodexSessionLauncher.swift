import Foundation
import TapQContracts
import TapQWireProtocol

/// Starts Codex sessions from nothing, and owns the ones it starts — the Codex half of
/// what `OwnedClaudeSessionLauncher` does for Claude Code (2026-09-04, parity pass).
///
/// The books, the sweep, the detach grace, the contact timeout, and the "own children only"
/// rule are the Claude launcher's, kept in step rather than shared, because the one thing
/// that differs is load-bearing enough to shape the type:
///
/// **The id is discovered, not chosen.** `codex exec` has no way to be told its thread id
/// (verified against `codex-rs/exec/src/cli.rs`, 2026-09-04: `--session-id` exists only for
/// `resume` and `fork`). What it has is `--json`, whose first line is
/// `{"type":"thread.started","thread_id":"…"}`. So the spawn is filed under a
/// **provisional** id, the child's standard output is read until that line arrives, and the
/// record is re-keyed to the real id and handed to ``onIdentified``. Until then the session
/// is one TapQ started and cannot yet address; a child that never says who it is ends the
/// way a Claude child that never reports in does — the contact timeout kills it — because
/// the failure is the same one, seen from the other side.
///
/// **Hooks are bypassed into trust.** Codex runs a non-managed hook only after the user has
/// trusted its definition hash in `/hooks`, and a folder TapQ made a moment ago has hooks no
/// one has trusted. `--dangerously-bypass-hook-trust` runs the enabled hooks anyway for this
/// invocation — Codex's own flag for "automation that already vets hook sources", which is
/// exactly what a folder TapQ wrote is. It is scoped to the one process and changes no
/// trust state.
///
/// **Approvals are bypassed too**, with `--dangerously-bypass-approvals-and-sandbox`: the
/// Codex spelling of the `bypassPermissions` the maintainer chose for owned Claude sessions
/// on 2026-09-04, and for the same reason — a headless session has no dialog to fall back
/// to, and one that stalls on an approval nobody can see is worse than one that runs.
@MainActor public final class OwnedCodexSessionLauncher: OwnedSessionOwning {
    /// What the composition decides about every spawn.
    public struct Configuration: Sendable {
        /// The agent CLI to resolve on `PATH`.
        public var executableName: String
        /// The child's environment, passed through as given, for the reason the Claude
        /// launcher gives: the spawned session's hooks locate *this* broker through it.
        public var environment: [String: String]
        /// How many sessions TapQ may own at once, focused and winding down together.
        public var maximumOwnedSessions: Int

        public init(
            environment: [String: String],
            executableName: String = "codex",
            maximumOwnedSessions: Int = OwnedSessionBudget.maximumOwnedSessions
        ) {
            self.environment = environment
            self.executableName = executableName
            self.maximumOwnedSessions = maximumOwnedSessions
        }
    }

    private let configuration: Configuration
    private let processRunner: any OwnedSessionProcessRunning
    private let hookStatus: @Sendable () -> CodexHookInstallationStatus
    private let workingDirectory: OwnedSessionWorkingDirectory
    private let record: OwnedSessionRecording
    private let provisionalIDFactory: @Sendable () -> String
    private let clock: @Sendable () -> Date
    private let diagnostics: TapQDiagnosticEmitter
    public let agent = AgentIdentity.codex

    private var sessions: [OwnedSession] = []
    private var detachedAt: [String: Date] = [:]

    public var onClosed: (@MainActor (OwnedSessionClosure) -> Void)?

    /// Called once per spawn when the child has said which thread it is: the id the session
    /// was filed under at launch, and the record as it now stands under the real one. The
    /// composition moves the focus and writes the session book here rather than at launch,
    /// because there was no id to write then.
    public var onIdentified: (@MainActor (_ provisionalID: String, _ session: OwnedSession) -> Void)?

    /// The prefix on every id this launcher mints for a session that has not yet said who
    /// it is. Never a thread id Codex could produce, so the two can never be confused.
    public nonisolated static let provisionalIDPrefix = "pending-codex-"

    /// - Parameters:
    ///   - hookStatus: TapQ's Codex hook registration as the installer reads it, for the
    ///     user-level file or the folder's own. Only ``CodexHookInstallationStatus/notInstalled``
    ///     refuses.
    ///   - workingDirectory: where the next session works, answered per launch.
    ///   - record: writes the goal to the wearer's memory on spawn and the outcome on ending.
    public init(
        configuration: Configuration,
        processRunner: any OwnedSessionProcessRunning,
        hookStatus: @escaping @Sendable () -> CodexHookInstallationStatus,
        workingDirectory: @escaping OwnedSessionWorkingDirectory,
        record: @escaping OwnedSessionRecording = { _, _ in },
        provisionalIDFactory: @escaping @Sendable () -> String = {
            OwnedCodexSessionLauncher.provisionalIDPrefix + UUID().uuidString.lowercased()
        },
        clock: @escaping @Sendable () -> Date = { Date() },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
        self.hookStatus = hookStatus
        self.workingDirectory = workingDirectory
        self.record = record
        self.provisionalIDFactory = provisionalIDFactory
        self.clock = clock
        self.diagnostics = TapQDiagnosticEmitter(
            category: "OwnedCodexSession", sink: diagnosticSink
        )
    }

    // MARK: - Launching

    public var ownedSessions: [OwnedSession] { sessions }

    public func launchOwnedSession(goal: String) -> OwnedSessionLaunch {
        discardEndedSessions(now: clock())

        guard let prompt = OwnedSessionPrompt.text(from: goal) else {
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
              OwnedSessionExecutable.isUsableDirectory(workingDirectoryPath)
        else {
            return refuse(.workingDirectoryUnusable, goal: goal)
        }
        guard let executablePath = OwnedSessionExecutable.resolve(
            named: configuration.executableName,
            environment: configuration.environment,
            workingDirectoryPath: workingDirectoryPath
        ) else {
            return refuse(
                .agentExecutableNotFound(agentDisplayName: agent.displayName), goal: goal
            )
        }

        let provisionalID = provisionalIDFactory()
        let spawn = OwnedSessionSpawn(
            executablePath: executablePath,
            arguments: Self.spawnArguments(
                workingDirectoryPath: workingDirectoryPath, prompt: prompt
            ),
            environment: configuration.environment.merging(
                [OwnedSessionEnvironment.ownedSessionKey: "1"],
                uniquingKeysWith: { _, owned in owned }
            ),
            workingDirectoryPath: workingDirectoryPath
        )

        // The reader runs on the runner's thread and hops to the main actor with only the
        // thread id: the one fact this launcher reads off a child's output. Every other
        // line is discarded where it arrives.
        let outcome = processRunner.launch(spawn) { [weak self] line in
            guard let threadID = Self.threadID(fromJSONLine: line) else { return }
            Task { @MainActor [weak self] in
                self?.noteIdentified(provisionalID: provisionalID, threadID: threadID)
            }
        }
        guard case .launched(let processIdentifier) = outcome else {
            return refuse(.spawnFailed(agentDisplayName: agent.displayName), goal: goal)
        }

        let session = OwnedSession(
            sessionID: provisionalID,
            agent: agent,
            processIdentifier: processIdentifier,
            goal: goal,
            startedAt: clock()
        )
        sessions.append(session)
        diagnostics.record("launched", fields: [
            "provisional": provisionalID,
            "pid": "\(processIdentifier)",
        ])
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

    /// The child said which thread it is. Re-keys the record and tells the composition.
    ///
    /// Public so a test can drive it without a runner that reads; the shipping path is the
    /// stdout reader above. Ignored for a provisional id that is no longer in the books
    /// (the child exited or was swept first) and for one already identified.
    public func noteIdentified(provisionalID: String, threadID: String) {
        guard let index = sessions.firstIndex(where: { $0.sessionID == provisionalID }),
              !threadID.isEmpty
        else {
            diagnostics.record("identified.unknown", level: .warning,
                               fields: ["provisional": provisionalID])
            return
        }
        let existing = sessions[index]
        let identified = OwnedSession(
            sessionID: threadID,
            agent: existing.agent,
            processIdentifier: existing.processIdentifier,
            goal: existing.goal,
            startedAt: existing.startedAt,
            contactedAt: existing.contactedAt
        )
        sessions[index] = identified
        if let detached = detachedAt.removeValue(forKey: provisionalID) {
            detachedAt[threadID] = detached
        }
        diagnostics.record("identified", fields: [
            "provisional": provisionalID, "session": threadID,
        ])
        onIdentified?(provisionalID, identified)
    }

    /// Whether the session is still waiting to hear its own id.
    public func isAwaitingIdentity(sessionID: String) -> Bool {
        sessionID.hasPrefix(Self.provisionalIDPrefix) && indexOfSession(id: sessionID) != nil
    }

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

    public func owns(sessionID: String) -> Bool { indexOfSession(id: sessionID) != nil }

    public var activeSessions: [OwnedSession] {
        sessions.filter { detachedAt[$0.sessionID] == nil }
    }

    // MARK: - Detaching

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

    public func isDetached(sessionID: String) -> Bool {
        guard let index = indexOfSession(id: sessionID) else { return false }
        return detachedAt[sessions[index].sessionID] != nil
    }

    private func indexOfSession(id: String) -> Int? {
        sessions.firstIndex { $0.sessionID.caseInsensitiveCompare(id) == .orderedSame }
    }

    // MARK: - Lifecycle

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

    @discardableResult
    public func shutdown() -> [OwnedSessionClosure] {
        let closures = sessions.map {
            OwnedSessionClosure(session: $0, ending: .terminatedOnShutdown)
        }
        sessions = []
        for closure in closures { close(closure) }
        return closures
    }

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

    private func ending(for session: OwnedSession, now: Date) -> OwnedSessionEnding? {
        guard processRunner.isRunning(processIdentifier: session.processIdentifier) else {
            return session.hasReportedIn ? .exited : .exitedBeforeContact
        }
        if let detached = detachedAt[session.sessionID],
           now.timeIntervalSince(detached) >= OwnedSessionBudget.detachGrace {
            return .detached
        }
        guard !session.hasReportedIn else { return nil }
        guard now.timeIntervalSince(session.startedAt) >= OwnedSessionBudget.contactTimeout else {
            return nil
        }
        return .contactTimedOut
    }

    // MARK: - The argument vector

    /// The whole of what TapQ asks Codex to do, in order.
    ///
    /// Verified against `codex-rs/exec/src/cli.rs` and `codex-rs/utils/cli/src/shared_options.rs`
    /// at `main`, 2026-09-04. `exec` runs a non-interactive session; `--json` prints the
    /// event stream this launcher reads its thread id from; `--skip-git-repo-check` because
    /// a folder made under `--no-session-git` is not a repository and the session should
    /// start anyway; `--cd` names the folder explicitly even though the process starts
    /// there, so the agent's own idea of its root cannot drift from TapQ's;
    /// `--dangerously-bypass-approvals-and-sandbox` and `--dangerously-bypass-hook-trust`
    /// are explained on the type. The prompt is the positional argument.
    static func spawnArguments(workingDirectoryPath: String, prompt: String) -> [String] {
        [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
            "--cd", workingDirectoryPath,
            prompt,
        ]
    }

    /// The thread id on one line of `codex exec --json` output, or `nil` for any other
    /// line. The shape is `{"type":"thread.started","thread_id":"…"}` (`codex-rs/exec/src/
    /// exec_events.rs`); everything else — turn events, items, a line that is not JSON — is
    /// not this launcher's to read.
    nonisolated static func threadID(fromJSONLine line: String) -> String? {
        guard let object = try? JSONDecoder().decode(
            [String: JSONValue].self, from: Data(line.utf8)
        ), object["type"]?.stringValue == "thread.started",
              let threadID = object["thread_id"]?.stringValue,
              !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return threadID
    }
}
