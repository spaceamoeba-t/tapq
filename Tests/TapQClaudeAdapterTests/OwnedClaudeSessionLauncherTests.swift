import XCTest
@testable import TapQClaudeAdapter
import TapQContracts

/// A process boundary that starts nothing.
///
/// Every test in this file runs against it, and that is the point: the launcher's whole job
/// is deciding *whether* and *how* to start an agent, and none of those decisions should need
/// a real `claude` to prove. Nothing here spawns a session.
private final class RecordingProcessRunner: OwnedSessionProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var spawnsStorage: [OwnedSessionSpawn] = []
    private var terminatedStorage: [Int32] = []
    private var outcomeStorage: OwnedSessionSpawnOutcome = .launched(processIdentifier: 4242)
    private var runningStorage: Set<Int32> = [4242]

    var spawns: [OwnedSessionSpawn] {
        lock.lock(); defer { lock.unlock() }
        return spawnsStorage
    }

    var terminated: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return terminatedStorage
    }

    func setOutcome(_ outcome: OwnedSessionSpawnOutcome) {
        lock.lock(); defer { lock.unlock() }
        outcomeStorage = outcome
    }

    /// Marks a child as gone, the way an exited `claude` would look on the next sweep.
    func markExited(_ processIdentifier: Int32) {
        lock.lock(); defer { lock.unlock() }
        runningStorage.remove(processIdentifier)
    }

    func launch(_ spawn: OwnedSessionSpawn) -> OwnedSessionSpawnOutcome {
        lock.lock(); defer { lock.unlock() }
        spawnsStorage.append(spawn)
        return outcomeStorage
    }

    func isRunning(processIdentifier: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runningStorage.contains(processIdentifier)
    }

    func terminate(processIdentifier: Int32) {
        lock.lock(); defer { lock.unlock() }
        terminatedStorage.append(processIdentifier)
        runningStorage.remove(processIdentifier)
    }
}

/// The injected clock, in a box the launcher's `@Sendable` closure may capture.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return instant }
        set { lock.lock(); instant = newValue; lock.unlock() }
    }

    func advance(_ interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

/// Rung H leg 2: TapQ starting a session from nothing, and owning what it started.
///
/// Two claims are load-bearing and everything else supports them. The first is that the
/// session id is TapQ's own choice, so "the session I spawned is session X" is knowable
/// before the process exists and provable afterwards by the hook traffic that confirms it.
/// The second is that TapQ signals only children it started, and only for the endings that
/// call for it — including, under session focus (`docs/SESSION_FOCUS_PLAN.md`), a detached
/// child that did not exit inside its grace.
@MainActor final class OwnedClaudeSessionLauncherTests: XCTestCase {
    private var workingDirectory: URL!
    private var binDirectory: URL!
    private let processIdentifier: Int32 = 4242

    private let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    private var startedAt: Date { clock.now }
    private var recorded: [(goal: String, outcome: String)] = []

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-owned-\(UUID().uuidString)")
        workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true
        )
        // A file that resolves as `claude` on PATH and is never executed: the injected runner
        // is what "starts" it.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: binDirectory.appendingPathComponent("claude").path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: UInt16(0o755))]
        ))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Building one

    private func configuration(
        settingSources: [String]? = ["user", "project", "local"],
        pathOverride: String? = nil,
        maximumOwnedSessions: Int = OwnedSessionBudget.maximumOwnedSessions
    ) -> OwnedClaudeSessionLauncher.Configuration {
        OwnedClaudeSessionLauncher.Configuration(
            environment: [
                "PATH": pathOverride ?? binDirectory.path,
                "TAPQ_BROKER_DIR": "/tmp/tapq-broker",
            ],
            settingSources: settingSources,
            maximumOwnedSessions: maximumOwnedSessions
        )
    }

    /// Session ids for the sessions a test starts, in order. The default factory hands out
    /// the first for the first launch and so on, so a test that starts two can tell them
    /// apart; a test that passes `sessionID:` pins one.
    private nonisolated static let sessionIDs = [
        "11111111-2222-3333-4444-555555555555",
        "22222222-3333-4444-5555-666666666666",
        "33333333-4444-5555-6666-777777777777",
    ]

    private func makeLauncher(
        configuration: OwnedClaudeSessionLauncher.Configuration? = nil,
        runner: RecordingProcessRunner,
        hookStatus: ClaudeHookInstallationStatus = .strict,
        workingDirectoryPath: String?? = nil,
        sessionID: String? = nil
    ) -> OwnedClaudeSessionLauncher {
        let clock = self.clock
        let directory: String? = workingDirectoryPath ?? workingDirectory.path
        let counter = SessionIDCounter()
        return OwnedClaudeSessionLauncher(
            configuration: configuration ?? self.configuration(),
            processRunner: runner,
            hookStatus: { hookStatus },
            workingDirectory: { directory },
            record: { [self] goal, outcome in recorded.append((goal, outcome)) },
            sessionIDFactory: { sessionID ?? counter.next() },
            clock: { clock.now }
        )
    }

    private final class SessionIDCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0

        func next() -> String {
            lock.lock(); defer { lock.unlock() }
            let id = sessionIDs[min(index, sessionIDs.count - 1)]
            index += 1
            return id
        }
    }

    // MARK: - The spawn configuration

    /// The argument vector, whole. It is asserted exactly rather than by "contains" because
    /// what is *absent* from it is part of the design: no permission-mode override, no
    /// skipped permissions, no tool allowlist. A session TapQ started must ask for what a
    /// session the wearer started asks for.
    func testASpawnCarriesPrintTheChosenSessionIDTheSettingSourcesAndThePrompt() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)

        let launch = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        guard case .started(let session) = launch else {
            return XCTFail("expected a started session, got \(launch)")
        }
        XCTAssertEqual(runner.spawns.count, 1)
        let spawn = try XCTUnwrap(runner.spawns.first)
        XCTAssertEqual(spawn.arguments, [
            "--print",
            "--session-id", "11111111-2222-3333-4444-555555555555",
            "--permission-mode", "bypassPermissions",
            "--setting-sources", "user,project,local",
            "start on the dark mode thing",
        ])
        XCTAssertEqual(spawn.workingDirectoryPath, workingDirectory.path)
        XCTAssertEqual(spawn.executablePath, binDirectory.appendingPathComponent("claude").path)
        XCTAssertEqual(session.agent, .claudeCode)
        XCTAssertEqual(session.goal, "start on the dark mode thing")
        XCTAssertEqual(session.processIdentifier, processIdentifier)
    }

    /// The spawned session's hooks find *this* broker through the environment. A launcher
    /// that filtered it out would produce the one failure this rung is most careful about: a
    /// session that runs and is never seen.
    func testTheChildInheritsTheBrokerLocationFromTheRuntimeEnvironment() async throws {
        let runner = RecordingProcessRunner()
        _ = makeLauncher(runner: runner).launchOwnedSession(goal: "run the tests")

        let spawn = try XCTUnwrap(runner.spawns.first)
        XCTAssertEqual(spawn.environment["TAPQ_BROKER_DIR"], "/tmp/tapq-broker")
    }

    /// The child is marked as TapQ's own, and only the child: the runtime's environment
    /// is passed through otherwise untouched. The hook shim reads the mark to forward
    /// every reply despite the bypass mode the session runs under.
    func testTheChildIsMarkedAsAnOwnedSession() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "run the tests")

        let spawn = try XCTUnwrap(runner.spawns.first)
        XCTAssertEqual(spawn.environment[OwnedClaudeSessionLauncher.ownedSessionEnvironmentKey], "1")
        XCTAssertEqual(OwnedClaudeSessionLauncher.ownedSessionEnvironmentKey, "TAPQ_OWNED_SESSION")
        XCTAssertEqual(spawn.environment["TAPQ_BROKER_DIR"], "/tmp/tapq-broker",
                       "the rest of the environment is the runtime's own")
    }

    /// No `--setting-sources` when the composition asks for none, and the prompt stays last.
    func testTheSettingSourcesFlagIsOmittedWhenTheCompositionAsksForNone() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(
            configuration: configuration(settingSources: nil), runner: runner
        )

        _ = launcher.launchOwnedSession(goal: "run the tests")

        let spawn = try XCTUnwrap(runner.spawns.first)
        XCTAssertEqual(spawn.arguments, [
            "--print", "--session-id", "11111111-2222-3333-4444-555555555555",
            "--permission-mode", "bypassPermissions", "run the tests",
        ])
    }

    /// A transcript that begins with a hyphen is the one way the wearer's words could be read
    /// as a flag instead of as the prompt.
    func testALeadingHyphenNeverReachesTheArgumentVectorAsAFlag() async throws {
        XCTAssertEqual(
            OwnedClaudeSessionLauncher.promptText(from: "--version please"), "version please"
        )
        XCTAssertEqual(
            OwnedClaudeSessionLauncher.promptText(from: "  fix\tthe\nbuild "), "fix the build"
        )
        XCTAssertNil(OwnedClaudeSessionLauncher.promptText(from: "   \n  "))
        XCTAssertNil(OwnedClaudeSessionLauncher.promptText(from: "---"))
    }

    /// A recognizer that never endpointed does not get to fail the spawn.
    func testARunawayTranscriptIsTruncatedRatherThanRefused() async throws {
        let goal = String(repeating: "a", count: OwnedSessionBudget.maximumGoalCharacters + 500)
        let prompt = try XCTUnwrap(OwnedClaudeSessionLauncher.promptText(from: goal))
        XCTAssertEqual(prompt.count, OwnedSessionBudget.maximumGoalCharacters)
    }

    // MARK: - Refusals (nothing is spawned, and the wearer hears why)

    /// Session focus: a second "new session" starts while the first is still owned. The
    /// composition detaches the old one afterwards; the launcher no longer stands in the way.
    func testASecondSessionStartsWhileTheFirstIsStillOwned() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)

        _ = launcher.launchOwnedSession(goal: "first goal")
        let second = launcher.launchOwnedSession(goal: "second goal")

        guard case .started(let session) = second else {
            return XCTFail("expected the second session to start, got \(second)")
        }
        XCTAssertEqual(session.sessionID, Self.sessionIDs[1])
        XCTAssertEqual(runner.spawns.count, 2)
        XCTAssertEqual(launcher.ownedSessions.count, 2)
        XCTAssertEqual(launcher.activeSessions.count, 2)
    }

    /// The one guard left: the bound on children winding down at once. It refuses out loud,
    /// and it clears as soon as a child exits.
    func testTheBoundOnOwnedChildrenRefusesOutLoudAndClearsWhenOneExits() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(
            configuration: configuration(maximumOwnedSessions: 1), runner: runner
        )

        _ = launcher.launchOwnedSession(goal: "first goal")
        let second = launcher.launchOwnedSession(goal: "second goal")

        XCTAssertEqual(second, .refused(.stillWindingDown(agentDisplayName: "Claude Code")))
        XCTAssertEqual(runner.spawns.count, 1)

        runner.markExited(processIdentifier)
        guard case .started = launcher.launchOwnedSession(goal: "third goal") else {
            return XCTFail("an exited child frees its slot on the next launch")
        }
    }

    // MARK: - Detaching (session focus)

    /// The focus moved on. Nothing is signalled at the detach itself — the child gets its
    /// grace to finish and exit — and the sweep after the grace kills it, in silence.
    func testADetachedChildIsKilledOnlyAfterItsGraceAndNothingIsSaid() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")
        launcher.noteContact(sessionID: Self.sessionIDs[0])

        XCTAssertTrue(launcher.detach(sessionID: Self.sessionIDs[0], now: clock.now))
        XCTAssertTrue(launcher.isDetached(sessionID: Self.sessionIDs[0]))
        XCTAssertTrue(launcher.activeSessions.isEmpty)
        XCTAssertEqual(launcher.ownedSessions.count, 1, "still owned while it winds down")
        XCTAssertTrue(runner.terminated.isEmpty)

        XCTAssertTrue(launcher.sweep(now: clock.now.addingTimeInterval(
            OwnedSessionBudget.detachGrace - 1
        )).isEmpty)
        XCTAssertTrue(runner.terminated.isEmpty, "inside the grace the child is left alone")

        let closures = launcher.sweep(now: clock.now.addingTimeInterval(
            OwnedSessionBudget.detachGrace
        ))
        XCTAssertEqual(closures.map(\.ending), [.detached])
        XCTAssertNil(closures.first?.ending.spoken, "the switch was announced already")
        XCTAssertEqual(runner.terminated, [processIdentifier])
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
        XCTAssertEqual(recorded.last?.outcome, "detached: stopped")
    }

    /// A detached child that exits on its own inside the grace ends as an ordinary exit and
    /// is never signalled.
    func testADetachedChildThatExitsOnItsOwnIsNotSignalled() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")
        launcher.noteContact(sessionID: Self.sessionIDs[0])
        launcher.detach(sessionID: Self.sessionIDs[0], now: clock.now)
        runner.markExited(processIdentifier)

        let closures = launcher.sweep(now: clock.now.addingTimeInterval(5))
        XCTAssertEqual(closures.map(\.ending), [.exited])
        XCTAssertTrue(runner.terminated.isEmpty)
        XCTAssertFalse(launcher.isDetached(sessionID: Self.sessionIDs[0]))
    }

    /// Only children TapQ started can be detached here, and only once.
    func testDetachIgnoresStrangersAndRepeats() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertFalse(launcher.detach(sessionID: "a-keyboard-session", now: clock.now))
        XCTAssertFalse(launcher.isDetached(sessionID: "a-keyboard-session"))
        XCTAssertTrue(launcher.detach(sessionID: Self.sessionIDs[0], now: clock.now))
        XCTAssertFalse(launcher.detach(sessionID: Self.sessionIDs[0], now: clock.now))
    }

    /// The working directory is answered per launch, and no answer is a refusal the wearer
    /// hears rather than a session started somewhere TapQ guessed.
    func testNoWorkingDirectoryIsARefusalAndNothingSpawns() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner, workingDirectoryPath: .some(nil))

        let launch = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertEqual(launch, .refused(.workingDirectoryUnusable))
        XCTAssertTrue(runner.spawns.isEmpty)
    }

    /// Refused before spawning rather than spawned and killed two minutes later: the remedy
    /// is an install, and the wearer should hear that before any work happens.
    func testNothingIsSpawnedWhenTapQsHooksAreNotInstalled() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner, hookStatus: .notInstalled)

        let launch = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertEqual(
            launch, .refused(.integrationNotInstalled(agentDisplayName: "Claude Code"))
        )
        XCTAssertTrue(runner.spawns.isEmpty)
    }

    /// A stale or mixed layout still routes some traffic to the broker, so it is not a
    /// refusal — the contact timeout is the backstop for the case where it turns out not to.
    func testAPartialHookLayoutStillSpawns() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner, hookStatus: .partial)

        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertEqual(runner.spawns.count, 1)
    }

    func testAGoalThatCapturedSilenceIsRefusedAndNothingSpawns() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)

        let launch = launcher.launchOwnedSession(goal: "   ")

        XCTAssertEqual(launch, .refused(.emptyGoal))
        XCTAssertTrue(runner.spawns.isEmpty)
    }

    func testAnAgentThatIsNotOnThisMachineIsRefusedByName() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(
            configuration: configuration(pathOverride: "/nonexistent-tapq-bin"), runner: runner
        )

        let launch = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertEqual(
            launch, .refused(.agentExecutableNotFound(agentDisplayName: "Claude Code"))
        )
        XCTAssertTrue(runner.spawns.isEmpty)
    }

    func testAProcessThatWillNotStartLeavesNothingOwned() async throws {
        let runner = RecordingProcessRunner()
        runner.setOutcome(.failed)
        let launcher = makeLauncher(runner: runner)

        let launch = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertEqual(launch, .refused(.spawnFailed(agentDisplayName: "Claude Code")))
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
    }

    /// Every refusal is speakable. A refusal the voice layer cannot say is a session the
    /// wearer waits for and never gets.
    func testEveryRefusalCarriesASentenceAndARecordedReason() async throws {
        let refusals: [OwnedSessionRefusal] = [
            .stillWindingDown(agentDisplayName: "Claude Code"),
            .emptyGoal,
            .integrationNotInstalled(agentDisplayName: "Claude Code"),
            .agentExecutableNotFound(agentDisplayName: "Claude Code"),
            .workingDirectoryUnusable,
            .spawnFailed(agentDisplayName: "Claude Code"),
            .agentNotStartable(agentDisplayName: "Codex"),
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.spoken.isEmpty, "\(refusal) has no sentence")
            XCTAssertFalse(refusal.recordedOutcome.isEmpty, "\(refusal) has no reason")
        }
    }

    // MARK: - The mapping

    /// The id is chosen, so the mapping exists before the process does. Hook traffic confirms
    /// it; traffic from a keyboard session is not ours and changes nothing.
    func testHookContactConfirmsTheChosenSessionAndIgnoresEveryOther() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertFalse(try XCTUnwrap(launcher.ownedSessions.first).hasReportedIn)
        XCTAssertFalse(launcher.noteContact(sessionID: "a-keyboard-session"))
        XCTAssertFalse(try XCTUnwrap(launcher.ownedSessions.first).hasReportedIn)

        clock.advance(3)
        XCTAssertTrue(launcher.noteContact(sessionID: "11111111-2222-3333-4444-555555555555"))

        let session = try XCTUnwrap(launcher.ownedSessions.first)
        XCTAssertTrue(session.hasReportedIn)
        XCTAssertEqual(session.contactedAt, startedAt)
        XCTAssertTrue(launcher.owns(sessionID: "11111111-2222-3333-4444-555555555555"))
    }

    /// A build that normalized the chosen UUID's case would still correlate.
    func testTheMappingMatchesRegardlessOfHowTheAgentCasesTheSessionID() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner, sessionID: "abc-DEF-123")
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertTrue(launcher.noteContact(sessionID: "ABC-def-123"))
        XCTAssertTrue(try XCTUnwrap(launcher.ownedSessions.first).hasReportedIn)
    }

    // MARK: - Endings

    /// The contact timeout: a session TapQ started, cannot see, and cannot answer approvals
    /// for is worse than none — it is holding the wearer's goal somewhere they cannot reach.
    func testASessionThatNeverReportsInIsKilledAndSpokenAbout() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertTrue(launcher.sweep(now: startedAt.addingTimeInterval(30)).isEmpty)

        let closures = launcher.sweep(
            now: startedAt.addingTimeInterval(OwnedSessionBudget.contactTimeout)
        )
        XCTAssertEqual(closures.count, 1)
        XCTAssertEqual(closures.first?.ending, .contactTimedOut)
        XCTAssertNotNil(closures.first?.ending.spoken)
        XCTAssertEqual(runner.terminated, [processIdentifier])
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
    }

    /// A session that reported in is never killed for being quiet. Once TapQ can see it, its
    /// life is the wearer's business and not a clock's.
    func testASessionThatReportedInIsNeverKilledForBeingQuiet() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")
        launcher.noteContact(sessionID: "11111111-2222-3333-4444-555555555555")

        let closures = launcher.sweep(
            now: startedAt.addingTimeInterval(OwnedSessionBudget.contactTimeout * 100)
        )
        XCTAssertTrue(closures.isEmpty)
        XCTAssertTrue(runner.terminated.isEmpty)
        XCTAssertEqual(launcher.ownedSessions.count, 1)
    }

    /// The fast form of the same failure: bad flags, a build that rejects `--session-id`, an
    /// unauthenticated CLI. The child is already gone, so nothing is signalled.
    func testAChildThatExitedBeforeReportingInEndsWithoutBeingSignalled() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")
        runner.markExited(processIdentifier)

        let closures = launcher.sweep(now: startedAt.addingTimeInterval(5))
        XCTAssertEqual(closures.first?.ending, .exitedBeforeContact)
        XCTAssertNotNil(closures.first?.ending.spoken)
        XCTAssertTrue(runner.terminated.isEmpty)
    }

    /// A finished headless run is the ordinary ending, and nothing is said about it: the
    /// session announced itself through the Stop path like any other.
    func testAFinishedRunEndsQuietly() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")
        launcher.noteContact(sessionID: "11111111-2222-3333-4444-555555555555")
        runner.markExited(processIdentifier)

        let closures = launcher.sweep(now: startedAt.addingTimeInterval(5))
        XCTAssertEqual(closures.first?.ending, .exited)
        XCTAssertNil(closures.first?.ending.spoken)
    }

    /// A session that is over stops blocking the next one even if nobody swept.
    func testAnEndedSessionDoesNotBlockTheNextNewTask() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "first goal")
        runner.markExited(processIdentifier)

        let second = launcher.launchOwnedSession(goal: "second goal")
        guard case .started = second else {
            return XCTFail("expected the next task to start, got \(second)")
        }
        XCTAssertEqual(runner.spawns.count, 2)
        XCTAssertEqual(launcher.ownedSessions.count, 1)
    }

    // MARK: - Shutdown

    func testShutdownStopsTheChildrenTapQStartedAndEmptiesTheBooks() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        let closures = launcher.shutdown()
        XCTAssertEqual(closures.map(\.ending), [.terminatedOnShutdown])
        XCTAssertNil(closures.first?.ending.spoken)
        XCTAssertEqual(runner.terminated, [processIdentifier])
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
    }

    func testShutdownWithNothingOwnedSignalsNothing() async throws {
        let runner = RecordingProcessRunner()
        runner.setOutcome(.failed)
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertTrue(launcher.shutdown().isEmpty)
        XCTAssertTrue(runner.terminated.isEmpty)
    }

    /// The rule at its lowest layer: the real runner's books are the only thing it will act
    /// on, so a process it did not launch is not running as far as it is concerned and is
    /// never signalled. This process is the strongest available example of one.
    func testTheRealRunnerDisownsEveryProcessItDidNotLaunch() async throws {
        let runner = POSIXOwnedSessionProcessRunner()
        XCTAssertFalse(
            runner.isRunning(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        )
        // A no-op by the same rule; if it were not, this call would signal a stranger.
        runner.terminate(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(runner.isRunning(processIdentifier: Int32.max))
    }

    // MARK: - The wearer's memory

    /// Recorded twice, and the pair is the point: a runtime that dies in between leaves
    /// "started" with no ending, which is exactly true.
    func testTheRecorderCarriesTheGoalAtTheStartAndTheOutcomeAtTheEnd() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)

        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.goal, "start on the dark mode thing")
        XCTAssertEqual(recorded.first?.outcome, "started")

        _ = launcher.shutdown()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.last?.goal, "start on the dark mode thing")
        XCTAssertEqual(recorded.last?.outcome, "stopped at shutdown")
    }

    /// A refusal is recorded too. The wearer asked for something and did not get it, and
    /// "why not" is a question they can ask tomorrow.
    func testARefusalIsRecordedWithItsReason() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner, hookStatus: .notInstalled)

        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.outcome, "refused: hooks not installed")
    }
}
