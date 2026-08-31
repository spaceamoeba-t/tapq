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
/// Two claims are load-bearing and everything else supports them. The first is that a spawn
/// happens only into emptiness — no live Claude Code session in the roster, none already
/// owned, hooks installed — because a second session takes name-routing away from the one the
/// wearer is using (`docs/FLEET_ROSTER_PLAN.md` rung E). The second is that the session id is
/// TapQ's own choice, so "the session I spawned is session X" is knowable before the process
/// exists and provable afterwards by the hook traffic that confirms it.
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
        pathOverride: String? = nil
    ) -> OwnedClaudeSessionLauncher.Configuration {
        OwnedClaudeSessionLauncher.Configuration(
            workingDirectoryPath: workingDirectory.path,
            environment: [
                "PATH": pathOverride ?? binDirectory.path,
                "TAPQ_BROKER_DIR": "/tmp/tapq-broker",
            ],
            settingSources: settingSources
        )
    }

    private func makeLauncher(
        configuration: OwnedClaudeSessionLauncher.Configuration? = nil,
        runner: RecordingProcessRunner,
        hookStatus: ClaudeHookInstallationStatus = .strict,
        agentIsLive: Bool = false,
        sessionID: String = "11111111-2222-3333-4444-555555555555"
    ) -> OwnedClaudeSessionLauncher {
        let clock = self.clock
        return OwnedClaudeSessionLauncher(
            configuration: configuration ?? self.configuration(),
            processRunner: runner,
            hookStatus: { hookStatus },
            agentIsLive: { agentIsLive },
            record: { [self] goal, outcome in recorded.append((goal, outcome)) },
            sessionIDFactory: { sessionID },
            clock: { clock.now }
        )
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

    /// No `--setting-sources` when the composition asks for none, and the prompt stays last.
    func testTheSettingSourcesFlagIsOmittedWhenTheCompositionAsksForNone() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(
            configuration: configuration(settingSources: nil), runner: runner
        )

        _ = launcher.launchOwnedSession(goal: "run the tests")

        let spawn = try XCTUnwrap(runner.spawns.first)
        XCTAssertEqual(spawn.arguments, [
            "--print", "--session-id", "11111111-2222-3333-4444-555555555555", "run the tests",
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

    /// The rung E guard. A second Claude Code session would make the name "Claude" resolve to
    /// neither, so TapQ refuses rather than taking name-routing away from the session the
    /// wearer is already using.
    func testAnAgentWithALiveSessionIsRefusedRatherThanGivenASecond() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner, agentIsLive: true)

        let launch = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        guard case .refused(let refusal) = launch else {
            return XCTFail("expected a refusal, got \(launch)")
        }
        XCTAssertEqual(refusal, .agentAlreadyLive(agentDisplayName: "Claude Code"))
        XCTAssertTrue(refusal.spoken.contains("Claude Code"))
        XCTAssertTrue(runner.spawns.isEmpty)
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
    }

    /// The same guard from TapQ's own books, which is what holds in the window between a
    /// spawn and the spawned session's first traffic — exactly when a second "new task" would
    /// otherwise slip past the roster.
    func testASecondNewTaskIsRefusedWhileTapQAlreadyOwnsASession() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)

        _ = launcher.launchOwnedSession(goal: "first goal")
        let second = launcher.launchOwnedSession(goal: "second goal")

        guard case .refused(let refusal) = second else {
            return XCTFail("expected a refusal, got \(second)")
        }
        XCTAssertEqual(refusal, .alreadyOwnsSession(agentDisplayName: "Claude Code"))
        XCTAssertEqual(runner.spawns.count, 1)
        XCTAssertEqual(launcher.ownedSessions.count, 1)
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
            .agentAlreadyLive(agentDisplayName: "Claude Code"),
            .alreadyOwnsSession(agentDisplayName: "Claude Code"),
            .emptyGoal,
            .integrationNotInstalled(agentDisplayName: "Claude Code"),
            .agentExecutableNotFound(agentDisplayName: "Claude Code"),
            .workingDirectoryUnusable,
            .spawnFailed(agentDisplayName: "Claude Code"),
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
        let launcher = makeLauncher(runner: runner, agentIsLive: true)
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
        let launcher = makeLauncher(runner: runner, agentIsLive: true)

        _ = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.outcome, "refused: agent already live")
    }
}
