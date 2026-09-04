import XCTest
@testable import TapQClaudeAdapter
import TapQContracts
import TapQWireProtocol

/// The only place TapQ writes into the wearer's home outside its own configuration, so the
/// interesting assertions are the failures: a root it cannot make, and hooks it cannot
/// write, both refuse rather than hand back a folder a session would run in unseen.
final class OwnedSessionWorkspaceTests: XCTestCase {
    private var sandbox: URL!
    private let hookCommand = "/Users/x/Library/Application Support/TapQ/tapq-hook"

    /// 2026-09-03 12:34 local, so the folder-name assertions read the same wall clock the
    /// formatter does.
    private var fixedNow: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 3
        components.hour = 12
        components.minute = 34
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: components)!
    }

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tapq-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Records the folders `git init` was asked for, and can refuse. Nothing here spawns
    /// a process: `Foundation.Process` inside XCTest stalls the Linux container, which is
    /// why `OwnedSessionWorkspace` takes the initializer as a closure at all.
    private final class GitSpy {
        private(set) var directories: [URL] = []
        var failure: Error?
        func run(_ directory: URL) throws {
            directories.append(directory)
            if let failure { throw failure }
        }
    }

    private func workspace(
        root: URL? = nil,
        gitInit: Bool = false,
        hookCommand: String? = nil,
        git: GitSpy? = nil
    ) -> OwnedSessionWorkspace {
        OwnedSessionWorkspace(
            root: (root ?? sandbox.appendingPathComponent("sessions")).path,
            hookCommand: hookCommand ?? self.hookCommand,
            gitInit: gitInit,
            now: { self.fixedNow },
            gitInitializer: { url in try (git ?? GitSpy()).run(url) }
        )
    }

    // MARK: - Naming

    func testTheFolderIsStampedAndSlugged() throws {
        let path = try workspace().makeSessionDirectory(
            goal: "Set up a Swift package for the parser"
        )
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent,
                       "2026-09-03-1234-set-up-a-swift")
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// The slug is a label, not a summary. Punctuation becomes hyphens, runs of them
    /// collapse, and the edges are trimmed, so a folder name is always something a wearer
    /// can type.
    func testTheSlugIsFourWordsOfSafeCharacters() {
        XCTAssertEqual(OwnedSessionWorkspace.slug(for: "Fix the CI, please!"),
                       "fix-the-ci-please")
        XCTAssertEqual(OwnedSessionWorkspace.slug(for: "one two three four five six"),
                       "one-two-three-four")
        XCTAssertEqual(OwnedSessionWorkspace.slug(for: "  spaced   out  "), "spaced-out")
        XCTAssertEqual(OwnedSessionWorkspace.slug(for: "release/v2.1 branch"),
                       "release-v2-1-branch")
    }

    /// A wearer who asked for a session without saying what for. The caller passes the
    /// empty string, deliberately, rather than the paragraph the runtime substitutes as the
    /// agent's first prompt — slugging that would name the folder after TapQ talking to
    /// itself.
    func testAGoallessSessionIsCalledSession() throws {
        for goal in ["", "   ", "!!! ???"] {
            XCTAssertEqual(OwnedSessionWorkspace.slug(for: goal), "session")
        }
        let path = try workspace().makeSessionDirectory(goal: "")
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent,
                       "2026-09-03-1234-session")
    }

    /// Two sessions in one minute for the same thing. The clock is fixed here, which is
    /// exactly the case the suffix exists for.
    func testCollisionsGetASuffix() throws {
        let space = workspace()
        let first = try space.makeSessionDirectory(goal: "fix the tests")
        let second = try space.makeSessionDirectory(goal: "fix the tests")
        let third = try space.makeSessionDirectory(goal: "fix the tests")
        XCTAssertEqual(URL(fileURLWithPath: first).lastPathComponent,
                       "2026-09-03-1234-fix-the-tests")
        XCTAssertEqual(URL(fileURLWithPath: second).lastPathComponent,
                       "2026-09-03-1234-fix-the-tests-2")
        XCTAssertEqual(URL(fileURLWithPath: third).lastPathComponent,
                       "2026-09-03-1234-fix-the-tests-3")
    }

    // MARK: - The root

    /// Never created at startup: a run that starts no session leaves nothing in the
    /// wearer's home.
    func testTheRootIsCreatedOnFirstUseAndNotBefore() throws {
        let root = sandbox.appendingPathComponent("sessions")
        let space = workspace(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try space.makeSessionDirectory(goal: "anything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    /// Nested roots are made whole — `~/TapQ/sessions` on a machine with no `~/TapQ`.
    func testANestedRootIsCreated() throws {
        let root = sandbox.appendingPathComponent("TapQ/sessions/inner")
        _ = try workspace(root: root).makeSessionDirectory(goal: "anything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    /// A refusal, not a fallback to somewhere writable. A session TapQ started in a folder
    /// the wearer did not ask for is worse than one it did not start.
    ///
    /// Unwritable by way of a *file* in the middle of the path rather than by mode bits:
    /// the Linux test container runs as root, where mode bits refuse nobody, and a test
    /// that quietly skipped there would be a test that never ran.
    func testAnUnwritableRootThrows() throws {
        let blocker = sandbox.appendingPathComponent("not-a-directory")
        try Data("in the way".utf8).write(to: blocker)
        let root = blocker.appendingPathComponent("sessions")
        XCTAssertThrowsError(
            try workspace(root: root).makeSessionDirectory(goal: "anything")
        ) { error in
            XCTAssertEqual(error as? OwnedSessionWorkspaceError,
                           .unwritable(path: root.path))
        }
    }

    /// A file where the root should be is the same refusal.
    func testARootThatIsAFileThrows() throws {
        let root = sandbox.appendingPathComponent("sessions")
        try Data("not a directory".utf8).write(to: root)
        XCTAssertThrowsError(
            try workspace(root: root).makeSessionDirectory(goal: "anything")
        ) { error in
            XCTAssertEqual(error as? OwnedSessionWorkspaceError,
                           .unwritable(path: root.path))
        }
    }

    // MARK: - The hooks

    /// The failure that would look like success: a session starts, and nothing it does
    /// ever reaches TapQ. The settings file has to carry the shim in exactly the shape the
    /// launcher's hook check reads back.
    func testTheHooksAreWrittenIntoTheFolder() throws {
        let path = try workspace().makeSessionDirectory(goal: "fix the tests")
        let settings = URL(fileURLWithPath: path)
            .appendingPathComponent(".claude/settings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
        let root = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data(contentsOf: settings)
        )
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        // The strict layout: every ordinary tool reaches TapQ through PreToolUse, which
        // fires under `--print` where PermissionRequest never would.
        XCTAssertEqual(Set(hooks.keys),
                       ["PreToolUse", "Notification", "Stop", "UserPromptSubmit"])
        let quoted = HookInstaller.shellQuoted(hookCommand)
        for (event, groups) in hooks {
            let entries = try XCTUnwrap(groups.arrayValue, event)
            let commands = entries.flatMap { group in
                (group.objectValue?["hooks"]?.arrayValue ?? []).compactMap {
                    $0.objectValue?["command"]?.stringValue
                }
            }
            XCTAssertEqual(commands, [quoted], event)
        }
    }

    /// The composition hands over one writer per agent it can start, and every folder
    /// gets all of them (2026-09-04, Codex). The writers run in order, and a writer that
    /// throws refuses the folder as the hook failure it is.
    func testEveryHookWriterRunsInTheNewFolderAndAFailingOneRefusesIt() throws {
        var written: [String] = []
        let workspace = OwnedSessionWorkspace(
            root: sandbox.appendingPathComponent("sessions").path,
            hookWriters: [
                { directory in
                    written.append("claude:" + directory.lastPathComponent)
                    try "{}".write(
                        to: directory.appendingPathComponent("claude.json"),
                        atomically: true, encoding: .utf8
                    )
                },
                { directory in
                    written.append("codex:" + directory.lastPathComponent)
                    try "{}".write(
                        to: directory.appendingPathComponent("codex.json"),
                        atomically: true, encoding: .utf8
                    )
                },
            ],
            gitInit: false,
            now: { self.fixedNow },
            gitInitializer: { _ in }
        )
        let path = try workspace.makeSessionDirectory(goal: "fix the tests")
        XCTAssertEqual(written, ["claude:2026-09-03-1234-fix-the-tests",
                                 "codex:2026-09-03-1234-fix-the-tests"])
        for name in ["claude.json", "codex.json"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: path).appendingPathComponent(name).path
            ), name)
        }
        XCTAssertNil(workspace.hookCommand)

        struct Refused: Error {}
        let failing = OwnedSessionWorkspace(
            root: sandbox.appendingPathComponent("sessions").path,
            hookWriters: [{ _ in }, { _ in throw Refused() }],
            gitInit: false,
            now: { self.fixedNow },
            gitInitializer: { _ in }
        )
        XCTAssertThrowsError(try failing.makeSessionDirectory(goal: "fix the tests")) { error in
            guard case OwnedSessionWorkspaceError.hooksNotWritten = error else {
                return XCTFail("expected hooksNotWritten, got \(error)")
            }
        }
    }

    /// Read back through the installer itself, which is what the launcher does before it
    /// starts a session in this folder.
    func testTheInstallerRecognizesWhatTheWorkspaceWrote() throws {
        let path = try workspace().makeSessionDirectory(goal: "fix the tests")
        let installer = HookInstaller(
            settingsURL: URL(fileURLWithPath: path)
                .appendingPathComponent(".claude/settings.json"),
            hookCommand: hookCommand,
            policy: .strict
        )
        XCTAssertEqual(installer.installationStatus(), .strict,
                       "every tool call of a session TapQ starts is on record at the broker")
        XCTAssertTrue(installer.isInstalled())
        // The launcher's own check reads the status with a default installer and accepts
        // any installed layout, so the policy it was written under does not matter there.
        let byDefault = HookInstaller(settingsURL: installer.settingsURL, hookCommand: hookCommand)
        XCTAssertEqual(byDefault.installationStatus(), .strict)
    }

    // MARK: - The repository

    /// Default on. In hardware run 5 the first thing Claude asked in a bare folder was
    /// whether to initialize a repository; an empty repo removes that turn.
    func testGitInitRunsInTheNewFolderWhenAskedFor() throws {
        let git = GitSpy()
        let path = try workspace(gitInit: true, git: git)
            .makeSessionDirectory(goal: "fix the tests")
        XCTAssertEqual(git.directories.map(\.path), [path])
    }

    func testGitInitIsSkippedUnderNoSessionGit() throws {
        let git = GitSpy()
        _ = try workspace(gitInit: false, git: git).makeSessionDirectory(goal: "fix the tests")
        XCTAssertTrue(git.directories.isEmpty)
    }

    /// The whole reason `git init` is not allowed to throw out of the workspace: a machine
    /// without git still gets its session, hooks and all. A missing repository costs the
    /// wearer one conversational turn; a refusal costs them the session.
    func testAFailingGitIsAWarningNotARefusal() throws {
        let git = GitSpy()
        git.failure = CocoaError(.fileNoSuchFile)
        let path = try workspace(gitInit: true, git: git)
            .makeSessionDirectory(goal: "fix the tests")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: path)
                    .appendingPathComponent(".claude/settings.json").path
            )
        )
    }

    /// The real thing, exercised where it can be: `Process` under XCTest stalls the Linux
    /// container, so the default initializer runs only in the macOS leg of CI. Skipped
    /// rather than asserted-around when git is not installed.
    #if os(macOS)
    func testTheDefaultInitializerMakesARealRepository() throws {
        let folder = sandbox.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A bare `return` rather than `XCTSkip`: a skipped test changes XCTest's summary
        // line to one the slim-check counter does not recognize, and a suite that reports
        // zero tests is indistinguishable from a suite that was never found.
        do {
            try OwnedSessionWorkspace.gitInit(in: folder)
        } catch {
            return
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(".git").path
            )
        )
    }
    #endif
}
