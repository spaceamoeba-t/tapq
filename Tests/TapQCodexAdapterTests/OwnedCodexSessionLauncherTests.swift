import XCTest
@testable import TapQCodexAdapter
import TapQContracts

/// A process boundary that starts nothing and, unlike the Claude tests' double, can be made
/// to "say" lines on the child's standard output — which is how a Codex session tells TapQ
/// its thread id.
private final class RecordingProcessRunner: OwnedSessionProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var spawnsStorage: [OwnedSessionSpawn] = []
    private var terminatedStorage: [Int32] = []
    private var outcomeStorage: OwnedSessionSpawnOutcome = .launched(processIdentifier: 4242)
    private var runningStorage: Set<Int32> = [4242]
    private var readers: [@Sendable (String) -> Void] = []

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

    func markExited(_ processIdentifier: Int32) {
        lock.lock(); defer { lock.unlock() }
        runningStorage.remove(processIdentifier)
    }

    /// The child writes a line. Delivered on the calling thread, as the real runner's
    /// reader thread would.
    func emit(_ line: String) {
        lock.lock()
        let readers = self.readers
        lock.unlock()
        for reader in readers { reader(line) }
    }

    func launch(_ spawn: OwnedSessionSpawn) -> OwnedSessionSpawnOutcome {
        launch(spawn) { _ in }
    }

    func launch(
        _ spawn: OwnedSessionSpawn,
        standardOutput: @escaping @Sendable (String) -> Void
    ) -> OwnedSessionSpawnOutcome {
        lock.lock(); defer { lock.unlock() }
        spawnsStorage.append(spawn)
        readers.append(standardOutput)
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

/// TapQ starting a Codex session from nothing (2026-09-04, parity with the Claude launcher).
///
/// The load-bearing difference from the Claude suite: the session id is *discovered*. A spawn
/// is filed under a provisional id, the child's `--json` stream names the thread, and only
/// then does the record carry an id hook traffic can confirm. Everything else — the argument
/// vector, the refusals, the sweep, the detach grace, "own children only" — is asserted the
/// way the Claude suite asserts it.
@MainActor final class OwnedCodexSessionLauncherTests: XCTestCase {
    private var workingDirectory: URL!
    private var binDirectory: URL!
    private let processIdentifier: Int32 = 4242
    private let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    private var recorded: [(goal: String, outcome: String)] = []

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-owned-codex-\(UUID().uuidString)")
        workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: binDirectory.appendingPathComponent("codex").path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: UInt16(0o755))]
        ))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private func makeLauncher(
        runner: RecordingProcessRunner,
        hookStatus: CodexHookInstallationStatus = .installed,
        workingDirectoryPath: String?? = nil,
        pathOverride: String? = nil
    ) -> OwnedCodexSessionLauncher {
        let directory = workingDirectoryPath ?? workingDirectory.path
        return OwnedCodexSessionLauncher(
            configuration: .init(environment: [
                "PATH": pathOverride ?? binDirectory.path,
                "TAPQ_BROKER_DIR": "/tmp/tapq-broker",
            ]),
            processRunner: runner,
            hookStatus: { hookStatus },
            workingDirectory: { directory },
            record: { [self] goal, outcome in recorded.append((goal, outcome)) },
            provisionalIDFactory: { OwnedCodexSessionLauncher.provisionalIDPrefix + "aaaa" },
            clock: { [clock] in clock.now }
        )
    }

    private static let threadStartedLine =
        #"{"type":"thread.started","thread_id":"019a1b2c-3d4e-5f60-7182-93a4b5c6d7e8"}"#
    private static let threadID = "019a1b2c-3d4e-5f60-7182-93a4b5c6d7e8"

    /// Runs the main-actor hops the stdout reader schedules.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - The spawn

    /// `exec`, the JSON stream, no git check, the two bypasses, the folder, the prompt — in
    /// that order, and the child marked as owned in its environment with the broker
    /// location passed through.
    func testASpawnRunsExecWithTheJSONStreamTheBypassesAndThePrompt() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)

        let launch = launcher.launchOwnedSession(goal: "start on the dark mode thing")

        guard case .started(let session) = launch else {
            return XCTFail("expected a started session, got \(launch)")
        }
        let spawn = try XCTUnwrap(runner.spawns.first)
        XCTAssertEqual(spawn.arguments, [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
            "--cd", workingDirectory.path,
            "start on the dark mode thing",
        ])
        XCTAssertEqual(spawn.executablePath, binDirectory.appendingPathComponent("codex").path)
        XCTAssertEqual(spawn.workingDirectoryPath, workingDirectory.path)
        XCTAssertEqual(spawn.environment["TAPQ_BROKER_DIR"], "/tmp/tapq-broker")
        XCTAssertEqual(spawn.environment[OwnedSessionEnvironment.ownedSessionKey], "1")
        XCTAssertEqual(session.agent, .codex)
        XCTAssertEqual(session.goal, "start on the dark mode thing")
        XCTAssertTrue(session.sessionID.hasPrefix(OwnedCodexSessionLauncher.provisionalIDPrefix))
        XCTAssertTrue(launcher.isAwaitingIdentity(sessionID: session.sessionID))
        XCTAssertEqual(recorded.map(\.outcome), ["started"])
    }

    func testALeadingHyphenNeverReachesTheArgumentVectorAsAFlag() async throws {
        let runner = RecordingProcessRunner()
        _ = makeLauncher(runner: runner).launchOwnedSession(goal: "--version please")
        XCTAssertEqual(runner.spawns.first?.arguments.last, "version please")
    }

    // MARK: - The id, discovered

    /// The child says which thread it is; the record is re-keyed, the composition is told
    /// with both ids, and hook traffic under the real id now confirms the session.
    func testTheThreadStartedLineIdentifiesTheSessionOnce() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        var identified: [(provisional: String, session: OwnedSession)] = []
        launcher.onIdentified = { provisional, session in
            identified.append((provisional, session))
        }
        guard case .started(let provisional) = launcher.launchOwnedSession(goal: "run the tests")
        else { return XCTFail("not started") }

        runner.emit(#"{"type":"turn.started"}"#)
        runner.emit("not json at all")
        runner.emit(Self.threadStartedLine)
        runner.emit(Self.threadStartedLine)
        await settle()

        XCTAssertEqual(identified.count, 1, "one identification per spawn")
        XCTAssertEqual(identified.first?.provisional, provisional.sessionID)
        XCTAssertEqual(identified.first?.session.sessionID, Self.threadID)
        XCTAssertEqual(launcher.ownedSessions.map(\.sessionID), [Self.threadID])
        XCTAssertFalse(launcher.isAwaitingIdentity(sessionID: provisional.sessionID))
        XCTAssertFalse(launcher.owns(sessionID: provisional.sessionID))
        XCTAssertTrue(launcher.owns(sessionID: Self.threadID))
        XCTAssertTrue(launcher.noteContact(sessionID: Self.threadID.uppercased()))
        XCTAssertTrue(try XCTUnwrap(launcher.ownedSessions.first).hasReportedIn)
    }

    func testOnlyAThreadStartedLineCarriesAnID() async {
        XCTAssertEqual(
            OwnedCodexSessionLauncher.threadID(fromJSONLine: Self.threadStartedLine),
            Self.threadID
        )
        for line in [
            #"{"type":"turn.started","thread_id":"x"}"#,
            #"{"type":"thread.started","thread_id":""}"#,
            #"{"type":"thread.started"}"#,
            "thread.started",
            "",
        ] {
            XCTAssertNil(OwnedCodexSessionLauncher.threadID(fromJSONLine: line), line)
        }
    }

    /// A detach that landed while the session was still provisional follows it to the real
    /// id, so the grace clock is not reset by the rename.
    func testADetachSurvivesIdentification() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        guard case .started(let provisional) = launcher.launchOwnedSession(goal: "run the tests")
        else { return XCTFail("not started") }
        XCTAssertTrue(launcher.detach(sessionID: provisional.sessionID, now: clock.now))

        launcher.noteIdentified(provisionalID: provisional.sessionID, threadID: Self.threadID)

        XCTAssertTrue(launcher.isDetached(sessionID: Self.threadID))
        XCTAssertFalse(launcher.isDetached(sessionID: provisional.sessionID))
        clock.advance(OwnedSessionBudget.detachGrace)
        XCTAssertEqual(launcher.sweep(now: clock.now).map(\.ending), [.detached])
        XCTAssertEqual(runner.terminated, [processIdentifier])
    }

    /// A child that never says who it is is the Codex face of a child that never reports
    /// in: killed at the contact timeout and spoken about.
    func testASessionThatNeverIdentifiesItselfIsKilledAtTheContactTimeout() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "run the tests")

        clock.advance(OwnedSessionBudget.contactTimeout - 1)
        XCTAssertTrue(launcher.sweep(now: clock.now).isEmpty)
        clock.advance(1)
        let closures = launcher.sweep(now: clock.now)

        XCTAssertEqual(closures.map(\.ending), [.contactTimedOut])
        XCTAssertNotNil(closures.first?.ending.spoken)
        XCTAssertEqual(runner.terminated, [processIdentifier])
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
        XCTAssertEqual(recorded.map(\.outcome), ["started", "never reported in"])
    }

    /// An identification for a session already gone — the child exited and was swept before
    /// its line was read — is nothing, not a resurrection.
    func testALateIdentificationOfASweptSessionIsIgnored() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        var identified = 0
        launcher.onIdentified = { _, _ in identified += 1 }
        guard case .started(let provisional) = launcher.launchOwnedSession(goal: "run the tests")
        else { return XCTFail("not started") }
        runner.markExited(processIdentifier)
        XCTAssertEqual(launcher.sweep(now: clock.now).map(\.ending), [.exitedBeforeContact])

        launcher.noteIdentified(provisionalID: provisional.sessionID, threadID: Self.threadID)

        XCTAssertEqual(identified, 0)
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
    }

    // MARK: - Refusals

    func testNothingIsSpawnedWhenTapQsCodexHooksAreNotInstalled() async throws {
        let runner = RecordingProcessRunner()
        let launch = makeLauncher(runner: runner, hookStatus: .notInstalled)
            .launchOwnedSession(goal: "run the tests")
        XCTAssertEqual(launch, .refused(.integrationNotInstalled(agentDisplayName: "Codex")))
        XCTAssertTrue(runner.spawns.isEmpty)
        XCTAssertEqual(recorded.map(\.outcome), ["refused: hooks not installed"])
    }

    func testAPartialHookLayoutStillSpawns() async throws {
        let runner = RecordingProcessRunner()
        let launch = makeLauncher(runner: runner, hookStatus: .partial)
            .launchOwnedSession(goal: "run the tests")
        guard case .started = launch else { return XCTFail("expected a start, got \(launch)") }
        XCTAssertEqual(runner.spawns.count, 1)
    }

    func testAnAgentThatIsNotOnThisMachineIsRefusedByName() async throws {
        let runner = RecordingProcessRunner()
        let launch = makeLauncher(runner: runner, pathOverride: "/nonexistent")
            .launchOwnedSession(goal: "run the tests")
        XCTAssertEqual(launch, .refused(.agentExecutableNotFound(agentDisplayName: "Codex")))
        XCTAssertEqual(launch.refusalSpoken, "I couldn't find Codex on this machine.")
    }

    func testNoWorkingDirectoryIsARefusalAndNothingSpawns() async throws {
        let runner = RecordingProcessRunner()
        let launch = makeLauncher(runner: runner, workingDirectoryPath: .some(nil))
            .launchOwnedSession(goal: "run the tests")
        XCTAssertEqual(launch, .refused(.workingDirectoryUnusable))
        XCTAssertTrue(runner.spawns.isEmpty)
    }

    func testAGoalThatCapturedSilenceIsRefusedAndNothingSpawns() async throws {
        let runner = RecordingProcessRunner()
        let launch = makeLauncher(runner: runner).launchOwnedSession(goal: "  \n ")
        XCTAssertEqual(launch, .refused(.emptyGoal))
        XCTAssertTrue(runner.spawns.isEmpty)
    }

    func testAProcessThatWillNotStartLeavesNothingOwned() async throws {
        let runner = RecordingProcessRunner()
        runner.setOutcome(.failed)
        let launcher = makeLauncher(runner: runner)
        XCTAssertEqual(launcher.launchOwnedSession(goal: "run the tests"),
                       .refused(.spawnFailed(agentDisplayName: "Codex")))
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
    }

    // MARK: - Lifecycle

    func testAFinishedRunEndsQuietlyAndFreesTheSlot() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        var closed: [OwnedSessionClosure] = []
        launcher.onClosed = { closed.append($0) }
        guard case .started(let provisional) = launcher.launchOwnedSession(goal: "run the tests")
        else { return XCTFail("not started") }
        launcher.noteIdentified(provisionalID: provisional.sessionID, threadID: Self.threadID)
        launcher.noteContact(sessionID: Self.threadID)
        runner.markExited(processIdentifier)

        let closures = launcher.sweep(now: clock.now)

        XCTAssertEqual(closures.map(\.ending), [.exited])
        XCTAssertNil(closures.first?.ending.spoken)
        XCTAssertEqual(closed.map(\.session.sessionID), [Self.threadID])
        XCTAssertTrue(runner.terminated.isEmpty, "a child that exited on its own is not signalled")
        XCTAssertEqual(recorded.map(\.outcome), ["started", "session ended"])
    }

    func testShutdownStopsTheChildrenTapQStartedAndEmptiesTheBooks() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        _ = launcher.launchOwnedSession(goal: "run the tests")

        let closures = launcher.shutdown()

        XCTAssertEqual(closures.map(\.ending), [.terminatedOnShutdown])
        XCTAssertEqual(runner.terminated, [processIdentifier])
        XCTAssertTrue(launcher.ownedSessions.isEmpty)
        XCTAssertTrue(launcher.shutdown().isEmpty)
    }

    func testDetachIgnoresStrangersAndRepeats() async throws {
        let runner = RecordingProcessRunner()
        let launcher = makeLauncher(runner: runner)
        guard case .started(let provisional) = launcher.launchOwnedSession(goal: "run the tests")
        else { return XCTFail("not started") }

        XCTAssertFalse(launcher.detach(sessionID: "a-keyboard-session", now: clock.now))
        XCTAssertTrue(launcher.detach(sessionID: provisional.sessionID, now: clock.now))
        XCTAssertFalse(launcher.detach(sessionID: provisional.sessionID, now: clock.now))
        XCTAssertTrue(launcher.activeSessions.isEmpty)
        XCTAssertFalse(launcher.noteContact(sessionID: "a-keyboard-session"))
    }
}

private extension OwnedSessionLaunch {
    var refusalSpoken: String? {
        guard case .refused(let refusal) = self else { return nil }
        return refusal.spoken
    }
}
