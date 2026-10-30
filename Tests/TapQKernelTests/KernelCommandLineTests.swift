import Foundation
import XCTest
@testable import TapQKernel

/// `tapq-kernel`'s grammar, and the workspace directory `run` makes and
/// `clear` deletes.
@MainActor
final class KernelCommandLineTests: XCTestCase {

    // MARK: - Grammar

    func testHelpIsItsOwnInvocation() async throws {
        XCTAssertEqual(try KernelCommandLine.parse(["--help"]), .help)
        XCTAssertEqual(try KernelCommandLine.parse(["-h"]), .help)
        // Even with everything else wrong: asking what the flags are is not an error.
        XCTAssertEqual(try KernelCommandLine.parse(["run", "--nonsense", "--help"]), .help)
    }

    func testASubcommandComesFirst() async throws {
        XCTAssertThrowsError(try KernelCommandLine.parse([])) {
            XCTAssertEqual($0 as? KernelUsageError, .missingSubcommand)
        }
        XCTAssertThrowsError(try KernelCommandLine.parse(["--workspace", "/tmp"])) {
            XCTAssertEqual($0 as? KernelUsageError, .missingSubcommand)
        }
        for word in ["serve", "recording", "notes"] {
            XCTAssertThrowsError(try KernelCommandLine.parse([word, "--workspace", "/tmp"])) {
                XCTAssertEqual($0 as? KernelUsageError, .unexpectedArgument(word))
            }
        }
    }

    /// Opt-in (2026-10-12): one switch for both agents' own approvers.
    func testAutoModeIsOneFlagAndOffByDefault() async throws {
        guard case .run(let plain) = try KernelCommandLine.parse(["run", "--workspace", "/tmp"]),
              case .run(let auto) = try KernelCommandLine.parse(["run", "--workspace", "/tmp", "--auto-mode"])
        else { return XCTFail("expected runs") }
        XCTAssertFalse(plain.autoMode)
        XCTAssertTrue(auto.autoMode)
        XCTAssertTrue(KernelCommandLine.usage.contains("--auto-mode"))
        XCTAssertEqual(KernelUsageError.autoModeWithPermissionMode("manual").description,
                       "--auto-mode runs Claude Code in its auto mode, so it cannot be combined with "
                           + "--permission-mode manual")
    }

    func testRunDefaults() async throws {
        XCTAssertEqual(try KernelCommandLine.parse(["run", "--workspace", "/tmp"]),
                       .run(KernelCommandLine(workspace: URL(fileURLWithPath: "/tmp",
                                                             isDirectory: true)
                                                         .standardizedFileURL)))
        guard case .run(let options) = try KernelCommandLine.parse(["run", "--workspace", "/tmp"])
        else { return XCTFail("expected a run") }
        XCTAssertNil(options.permissionMode, "ClaudePermissionMode.standard")
        XCTAssertNil(options.realtimeEndpoint)
        XCTAssertNil(options.openAIBaseURL)
        XCTAssertEqual(options.language, "en")
        XCTAssertEqual(options.subscriptions, [], "every agent gets the environment as it is")
    }

    /// Names only; whether an agent can sign in with its subscription is its adapter's to
    /// say, at startup.
    func testSubscriptionsNameAgents() async throws {
        guard case .run(let one) = try KernelCommandLine
            .parse(["run", "--workspace", "/tmp", "--subscription", "claude"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(one.subscriptions, [.claude])
        guard case .run(let both) = try KernelCommandLine
            .parse(["run", "--workspace", "/tmp", "--subscription", "codex, claude"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(both.subscriptions, [.claude, .codex])
        for bad in ["chatgpt", "Claude", ""] {
            XCTAssertThrowsError(try KernelCommandLine.parse(
                ["run", "--workspace", "/tmp", "--subscription", "claude,\(bad)"]), bad
            ) { XCTAssertEqual($0 as? KernelUsageError, .unknownAgent(bad)) }
        }
        XCTAssertThrowsError(try KernelCommandLine.parse(
            ["run", "--workspace", "/tmp", "--subscription"])
        ) { XCTAssertEqual($0 as? KernelUsageError, .missingValue(flag: "--subscription")) }
        XCTAssertTrue(KernelCommandLine.usage.contains("--subscription <agents>"))
    }

    /// `--agents`: the agents this run may start; absent, every agent.
    func testAgentsNameTheAgentsARunMayStart() async throws {
        guard case .run(let all) = try KernelCommandLine.parse(["run", "--workspace", "/tmp"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertNil(all.planAgents, "no --agents: every agent")
        guard case .run(let one) = try KernelCommandLine
            .parse(["run", "--workspace", "/tmp", "--agents", "chatgpt"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(one.planAgents, [.chatgpt])
        guard case .run(let two) = try KernelCommandLine
            .parse(["run", "--workspace", "/tmp", "--agents", "claude, codex"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(two.planAgents, [.claude, .codex])
        for bad in ["cursor", "Claude", ""] {
            XCTAssertThrowsError(try KernelCommandLine.parse(["run", "--workspace", "/tmp", "--agents", "claude,\(bad)"]),
                                 bad) { XCTAssertEqual($0 as? KernelUsageError, .unknownPlanAgent(bad)) }
        }
        XCTAssertThrowsError(try KernelCommandLine.parse(["run", "--workspace", "/tmp", "--agents"])) {
            XCTAssertEqual($0 as? KernelUsageError, .missingValue(flag: "--agents"))
        }
        XCTAssertTrue(KernelCommandLine.usage.contains("--agents <agents>"))
    }

    /// Each chat agent is reached one way: in the user's app (`--desktop-chat`) or over the API
    /// (`--api-chat`), never both (2026-10-13). Off, the default, it is neither.
    func testEachChatIsReachedOneWay() async throws {
        guard case .run(let off) = try KernelCommandLine.parse(["run", "--workspace", "/tmp"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(off.chatBackends, [:])
        guard case .run(let split) = try KernelCommandLine.parse(
            ["run", "--workspace", "/tmp", "--desktop-chat", "claude-chat", "--api-chat", "chatgpt"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(split.desktopChats, [.claudeChat])
        XCTAssertEqual(split.apiChats, [.chatgpt])
        XCTAssertEqual(split.chatBackends, [.claudeChat: .app, .chatgpt: .api])
        guard case .run(let api) = try KernelCommandLine.parse(
            ["run", "--workspace", "/tmp", "--api-chat", "chatgpt, claude-chat"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(api.chatBackends, [.claudeChat: .api, .chatgpt: .api])
        XCTAssertThrowsError(try KernelCommandLine.parse(
            ["run", "--workspace", "/tmp", "--desktop-chat", "chatgpt", "--api-chat", "chatgpt"])
        ) { XCTAssertEqual($0 as? KernelUsageError, .chatInBothBackends("chatgpt")) }
        for bad in ["claude", "codex", "gpt", ""] {
            XCTAssertThrowsError(try KernelCommandLine.parse(
                ["run", "--workspace", "/tmp", "--api-chat", "chatgpt,\(bad)"]), bad
            ) { XCTAssertEqual($0 as? KernelUsageError, .unknownChatAgent(flag: "--api-chat", bad)) }
        }
        XCTAssertThrowsError(try KernelCommandLine.parse(
            ["run", "--workspace", "/tmp", "--desktop-chat", "claude"])
        ) { XCTAssertEqual($0 as? KernelUsageError, .unknownChatAgent(flag: "--desktop-chat", "claude")) }
        // Parsed, but this build links no chat agent, so the usage offers neither flag.
        XCTAssertFalse(KernelCommandLine.usage.contains("--api-chat"))
        XCTAssertFalse(KernelCommandLine.usage.contains("--desktop-chat"))
    }

    func testClearTakesOnlyTheWorkspace() async throws {
        XCTAssertEqual(try KernelCommandLine.parse(["clear", "--workspace", "/tmp/a/../b"]),
                       .clear(workspace: URL(fileURLWithPath: "/tmp/b", isDirectory: true)
                                .standardizedFileURL))
        XCTAssertThrowsError(try KernelCommandLine.parse(["clear"])) {
            XCTAssertEqual($0 as? KernelUsageError, .missingWorkspace)
        }
        XCTAssertThrowsError(
            try KernelCommandLine.parse(["clear", "--workspace", "/tmp", "--language", "en"])
        ) { XCTAssertEqual($0 as? KernelUsageError, .unknownFlag("--language")) }
    }

    func testTheWorkspaceIsRequiredAndAbsolute() async throws {
        XCTAssertThrowsError(try KernelCommandLine.parse(["run"])) {
            XCTAssertEqual($0 as? KernelUsageError, .missingWorkspace)
        }
        XCTAssertThrowsError(try KernelCommandLine.parse(["run", "--workspace"])) {
            XCTAssertEqual($0 as? KernelUsageError, .missingValue(flag: "--workspace"))
        }
        for relative in ["project", "./project", "~/project"] {
            XCTAssertThrowsError(try KernelCommandLine.parse(["run", "--workspace", relative])) {
                XCTAssertEqual($0 as? KernelUsageError, .relativeWorkspace(relative))
            }
        }
    }

    /// The flags §8 deleted are now plain unknown flags, never silently accepted.
    func testTheDeletedFlagsAreRefused() async throws {
        for flag in ["--resume", "--fresh", "--exit-on-stdin-eof"] {
            XCTAssertThrowsError(try KernelCommandLine.parse(["run", "--workspace", "/tmp", flag])) {
                XCTAssertEqual($0 as? KernelUsageError, .unknownFlag(flag))
            }
        }
        for flag in ["--voice-processing", "--setting-sources", "--audio"] {
            XCTAssertThrowsError(
                try KernelCommandLine.parse(["run", "--workspace", "/tmp", flag, "on"])
            ) { XCTAssertEqual($0 as? KernelUsageError, .unknownFlag(flag)) }
        }
        XCTAssertThrowsError(try KernelCommandLine.parse(["run", "--workspace", "/tmp", "extra"])) {
            XCTAssertEqual($0 as? KernelUsageError, .unexpectedArgument("extra"))
        }
    }

    func testTheLanguageIsAnISOCode() async throws {
        guard case .run(let german) = try KernelCommandLine
            .parse(["run", "--language", "de", "--workspace", "/tmp"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(german.language, "de")
        guard case .run(let mixed) = try KernelCommandLine
            .parse(["run", "--workspace", "/tmp", "--language", "auto"]) else {
            return XCTFail("expected a run")
        }
        XCTAssertNil(mixed.language, "auto tells the service no language")
        for bad in ["English", "EN", "e", "eng", "AUTO", "aut"] {
            XCTAssertThrowsError(
                try KernelCommandLine.parse(["run", "--workspace", "/tmp", "--language", bad])
            ) { XCTAssertEqual($0 as? KernelUsageError, .invalidLanguage(bad)) }
        }
        XCTAssertThrowsError(
            try KernelCommandLine.parse(["run", "--workspace", "/tmp", "--language", " "])
        ) { XCTAssertEqual($0 as? KernelUsageError, .missingValue(flag: "--language")) }
    }

    func testTheEndpointOverridesNeedTheirSchemes() async throws {
        guard case .run(let options) = try KernelCommandLine.parse(
            ["run", "--workspace", "/tmp",
             "--realtime-endpoint", "ws://127.0.0.1:4321/v1/realtime",
             "--openai-base-url", "http://127.0.0.1:4322/v1"])
        else { return XCTFail("expected a run") }
        XCTAssertEqual(options.realtimeEndpoint?.absoluteString, "ws://127.0.0.1:4321/v1/realtime")
        XCTAssertEqual(options.openAIBaseURL?.absoluteString, "http://127.0.0.1:4322/v1")

        for bad in ["http://127.0.0.1:1", "127.0.0.1:1", "ws://", "not a url"] {
            XCTAssertThrowsError(try KernelCommandLine.parse(
                ["run", "--workspace", "/tmp", "--realtime-endpoint", bad]), bad
            ) { XCTAssertEqual($0 as? KernelUsageError, .invalidRealtimeEndpoint(bad)) }
        }
        for bad in ["wss://api.openai.com/v1", "api.openai.com", "https://"] {
            XCTAssertThrowsError(try KernelCommandLine.parse(
                ["run", "--workspace", "/tmp", "--openai-base-url", bad]), bad
            ) { XCTAssertEqual($0 as? KernelUsageError, .invalidOpenAIBaseURL(bad)) }
        }
    }

    /// The mode is carried as typed; `ClaudePermissionMode.parse` judges it in the executable,
    /// so this layer keeps no second list (ClaudeLaunchSpecTests covers the refusals).
    func testThePermissionModeIsCarriedForTheClaudeAdapterToJudge() async throws {
        guard case .run(let options) = try KernelCommandLine
            .parse(["run", "--workspace", "/tmp", "--permission-mode", " manual "]) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(options.permissionMode, "manual")
        XCTAssertThrowsError(try KernelCommandLine.parse(
            ["run", "--workspace", "/tmp", "--permission-mode"])
        ) { XCTAssertEqual($0 as? KernelUsageError, .missingValue(flag: "--permission-mode")) }
    }

    func testTheUsageShowsBothSubcommandsAndNoDeletedFlag() async throws {
        let usage = KernelCommandLine.usage
        XCTAssertTrue(usage.contains("tapq-kernel run --workspace <abs-dir> [--language <code>|auto]"))
        XCTAssertTrue(usage.contains("tapq-kernel clear --workspace <abs-dir>"))
        for deleted in ["--resume", "--fresh", "--voice-processing", "--exit-on-stdin-eof",
                        "--audio"] {
            XCTAssertFalse(usage.contains(deleted), deleted)
        }
    }

    // MARK: - run's directory

    func testAMissingWorkspaceIsRefused() async throws {
        let root = try temporaryDirectory()
        let options = KernelCommandLine(workspace: root.appendingPathComponent("nope"))
        XCTAssertThrowsError(try KernelWorkspacePreparation.prepare(options, supportDirectory: root)) {
            guard case .workspaceMissing = $0 as? KernelUsageError else {
                return XCTFail("expected workspaceMissing, got \($0)")
            }
        }
    }

    func testAFileIsNotAWorkspace() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("a-file")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try KernelWorkspacePreparation.prepare(
            KernelCommandLine(workspace: file), supportDirectory: root)
        ) {
            guard case .workspaceNotADirectory = $0 as? KernelUsageError else {
                return XCTFail("expected workspaceNotADirectory, got \($0)")
            }
        }
    }

    /// The directory is private to its owner, and a second run finds the first one's files.
    func testTheKernelDirectoryIsPrivateAndKept() async throws {
        let (workspace, support) = try workspaceAndSupport()
        let options = KernelCommandLine(workspace: workspace)
        let directory = try KernelWorkspacePreparation.prepare(options, supportDirectory: support)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))

        let journal = directory.appendingPathComponent("journal.jsonl")
        try "{}\n".write(to: journal, atomically: true, encoding: .utf8)
        let again = try KernelWorkspacePreparation.prepare(options, supportDirectory: support)
        // `.path`: corelibs adds a trailing slash to a URL once its directory exists.
        XCTAssertEqual(again.path, directory.path)
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "{}\n")
    }

    // MARK: - clear

    /// The kernel directory goes, rotated diagnostics included; its siblings stay.
    func testClearDeletesTheDirectoryOnly() async throws {
        let (workspace, support) = try workspaceAndSupport()
        let directory = try KernelWorkspacePreparation.prepare(
            KernelCommandLine(workspace: workspace), supportDirectory: support)
        for name in ["journal.jsonl", "diagnostics.log", "diagnostics.log.1"] {
            try "x\n".write(to: directory.appendingPathComponent(name),
                            atomically: true, encoding: .utf8)
        }
        let parent = directory.deletingLastPathComponent()
        let kept = ["\(directory.lastPathComponent).20260901-101500", "other"]
        for name in kept {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }

        try KernelWorkspacePreparation.clear(workspace: workspace, supportDirectory: support)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        XCTAssertEqual(remaining, kept.sorted())
    }

    /// A workspace folder that is gone can still be cleared; one never run clears nothing.
    func testClearNeedsNoWorkspaceFolder() async throws {
        let root = try temporaryDirectory()
        let support = root.appendingPathComponent("support", isDirectory: true)
        let gone = root.appendingPathComponent("gone", isDirectory: true)
        XCTAssertNoThrow(try KernelWorkspacePreparation.clear(workspace: gone,
                                                              supportDirectory: support))

        let directory = KernelPaths.directory(supportDirectory: support, workspace: gone)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try KernelWorkspacePreparation.clear(workspace: gone, supportDirectory: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kernel-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    private func workspaceAndSupport() throws -> (workspace: URL, support: URL) {
        let root = try temporaryDirectory()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return (workspace.standardizedFileURL, support.standardizedFileURL)
    }
}
