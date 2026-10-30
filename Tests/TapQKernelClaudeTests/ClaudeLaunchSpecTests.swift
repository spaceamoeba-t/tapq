import Foundation
import XCTest
import TapQContracts
import TapQKernel
@testable import TapQKernelClaude

/// The command line, the refused mode, and the environment the child is spawned into.
/// Nothing here starts a process.
final class ClaudeLaunchSpecTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
    private let sessionID = UUID(uuidString: "2EF4A829-1045-4F5B-B7FE-38E4270D704E")!

    // MARK: - argv

    func testAFreshSessionPassesSessionIDAndTheDefaultFlags() {
        let spec = ClaudeLaunchSpec(executablePath: "/usr/local/bin/claude",
                                    workspace: workspace,
                                    session: .fresh(sessionID))
        XCTAssertEqual(spec.arguments, [
            "--print", "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", "acceptEdits",
            "--session-id", "2ef4a829-1045-4f5b-b7fe-38e4270d704e",
            "--setting-sources", "user,project,local",
        ])
    }

    func testAModelGoesBeforeTheSessionAsTheModelFlag() {
        let spec = ClaudeLaunchSpec(executablePath: "/usr/local/bin/claude",
                                    workspace: workspace,
                                    model: "claude-haiku-5-5",
                                    session: .fresh(sessionID))
        XCTAssertEqual(Array(spec.arguments.dropFirst(8)), [
            "--permission-mode", "acceptEdits",
            "--model", "claude-haiku-5-5",
            "--session-id", "2ef4a829-1045-4f5b-b7fe-38e4270d704e",
            "--setting-sources", "user,project,local",
        ])
        XCTAssertFalse(ClaudeLaunchSpec(executablePath: "claude", workspace: workspace, model: "",
                                        session: .fresh(sessionID)).arguments.contains("--model"))
    }

    func testTheModelIsHaikuUnlessTheEnvironmentNamesAnother() {
        XCTAssertEqual(ClaudeLaunchSpec.resolvedModel(environment: [:]), "claude-haiku-5-5")
        XCTAssertEqual(ClaudeLaunchSpec.resolvedModel(environment: ["TAPQ_CLAUDE_MODEL": " sonnet "]), "sonnet")
        XCTAssertEqual(ClaudeLaunchSpec.resolvedModel(environment: ["TAPQ_CLAUDE_MODEL": "  "]), "claude-haiku-5-5")
    }

    func testAResumedSessionPassesResumeInstead() {
        let spec = ClaudeLaunchSpec(executablePath: "/usr/local/bin/claude",
                                    workspace: workspace,
                                    session: .resume("2ef4a829-1045-4f5b-b7fe-38e4270d704e"))
        XCTAssertEqual(spec.arguments.suffix(4),
                       ["--resume", "2ef4a829-1045-4f5b-b7fe-38e4270d704e",
                        "--setting-sources", "user,project,local"])
    }

    /// K0 07-resume passed `--resume` alone and got the same session id back. The enum is
    /// what makes "exactly one of them" true by construction.
    func testTheTwoSessionFlagsAreMutuallyExclusive() {
        let fresh = ClaudeLaunchSpec(executablePath: "claude",
                                     workspace: workspace,
                                     session: .fresh(sessionID)).arguments
        XCTAssertTrue(fresh.contains("--session-id"))
        XCTAssertFalse(fresh.contains("--resume"))

        let resumed = ClaudeLaunchSpec(executablePath: "claude",
                                       workspace: workspace,
                                       session: .resume("abc")).arguments
        XCTAssertTrue(resumed.contains("--resume"))
        XCTAssertFalse(resumed.contains("--session-id"))
    }

    func testEveryPermissionModeReachesTheCommandLine() {
        for mode in ClaudePermissionMode.allCases {
            let spec = ClaudeLaunchSpec(executablePath: "claude",
                                        workspace: workspace,
                                        permissionMode: mode,
                                        session: .fresh(sessionID))
            guard let index = spec.arguments.firstIndex(of: "--permission-mode") else {
                return XCTFail("no --permission-mode for \(mode)")
            }
            XCTAssertEqual(spec.arguments[index + 1], mode.rawValue)
        }
        XCTAssertEqual(Set(ClaudePermissionMode.allCases.map(\.rawValue)),
                       ["acceptEdits", "manual", "dontAsk", "auto"])
    }

    func testSettingSourcesAreJoinedWithCommasAndOmittedWhenAbsent() {
        func arguments(_ sources: [String]?) -> [String] {
            ClaudeLaunchSpec(executablePath: "claude",
                             workspace: workspace,
                             settingSources: sources,
                             session: .fresh(sessionID)).arguments
        }
        XCTAssertEqual(arguments(["project"]).suffix(2), ["--setting-sources", "project"])
        XCTAssertEqual(arguments(["user", "project", "local"]).suffix(2),
                       ["--setting-sources", "user,project,local"])
        XCTAssertFalse(arguments(nil).contains("--setting-sources"))
        XCTAssertFalse(arguments([]).contains("--setting-sources"))
    }

    /// No `--include-partial-messages` in the MVP: an assistant message is only emitted
    /// once complete, and the loop is built around that.
    func testTheMVPDoesNotAskForPartialMessages() {
        let spec = ClaudeLaunchSpec(executablePath: "claude",
                                    workspace: workspace,
                                    session: .fresh(sessionID))
        XCTAssertFalse(spec.arguments.contains("--include-partial-messages"))
    }

    // MARK: - Permission modes

    func testTheDefaultModeIsAcceptEdits() {
        XCTAssertEqual(ClaudePermissionMode.standard, .acceptEdits)
        XCTAssertEqual(ClaudeLaunchSpec(executablePath: "claude",
                                        workspace: workspace,
                                        session: .fresh(sessionID)).permissionMode,
                       .acceptEdits)
    }

    /// It answers permission questions inside the CLI, so `can_use_tool` would never
    /// arrive and approve/deny would be dead verbs.
    func testBypassPermissionsIsRefusedByName() {
        XCTAssertThrowsError(try ClaudePermissionMode.parse("bypassPermissions")) { error in
            XCTAssertEqual(error as? ClaudeLaunchError,
                           .refusedPermissionMode("bypassPermissions"))
            XCTAssertTrue("\(error)".contains("refused"), "\(error)")
        }
        XCTAssertFalse(ClaudePermissionMode.allCases.map(\.rawValue).contains("bypassPermissions"))
    }

    func testParseAcceptsEveryModeTheCLIOffersAndRejectsTheRest() throws {
        for mode in ClaudePermissionMode.allCases where mode != .auto {
            XCTAssertEqual(try ClaudePermissionMode.parse(mode.rawValue), mode)
        }
        XCTAssertEqual(try ClaudePermissionMode.parse("  acceptEdits "), .acceptEdits)
        // 2.1.260 has no `default` mode; `manual` is the closest thing (K0).
        XCTAssertThrowsError(try ClaudePermissionMode.parse("default")) { error in
            XCTAssertEqual(error as? ClaudeLaunchError, .unknownPermissionMode("default"))
        }
        XCTAssertThrowsError(try ClaudePermissionMode.parse("acceptedits"))
        // `auto` is opt-in since 2026-10-12, by `--auto-mode` alone; `plan` answers inside the
        // CLI, out of the user's hearing (V2 P2-2).
        XCTAssertThrowsError(try ClaudePermissionMode.parse("auto")) { error in
            XCTAssertEqual(error as? ClaudeLaunchError, .autoModeIsAFlag)
        }
        for mode in ["plan"] {
            XCTAssertThrowsError(try ClaudePermissionMode.parse(mode)) { error in
                XCTAssertEqual(error as? ClaudeLaunchError, .unknownPermissionMode(mode))
            }
        }
    }

    // MARK: - Environment

    /// 02-7, 08-2: what reaches the child, name by name.
    func testTheChildEnvironmentPolicy() {
        let removed = [
            "OPENAI_API_KEY", "TAPQ_OPENAI_API_KEY", "TAPQ_ALLOW_UNSUPPORTED_AGENT_VERSIONS",
            "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
            "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_BRIDGE_SESSION_ID",
            "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
        ]
        let kept = [
            "PATH", "HOME", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
            "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CONFIG_DIR", "AWS_REGION", "OPENAI_BASE_URL", "TAPQ", "MY_TAPQ_FLAG",
        ]
        var environment: [String: String] = [:]
        for name in removed + kept { environment[name] = "value of \(name)" }
        XCTAssertEqual(ClaudeEnvironment.sanitized(environment),
                       Dictionary(uniqueKeysWithValues: kept.map { ($0, "value of \($0)") }))
    }

    // MARK: - Subscription

    /// `claude auth status --json` as 2.1.283 printed it for a Max login with no key in the
    /// environment (email and organization left out).
    func testAClaudeAILoginIsTheSubscriptionAccount() {
        let status = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","#
            + #""subscriptionType":"max"}"#
        XCTAssertEqual(ClaudeSubscription.status(statusOutput: status),
                       .account(SubscriptionAccount(method: "claude.ai", plan: "max")))
    }

    /// Each says what the CLI would use instead, and none repeats the report (its email).
    func testAnythingElseSaysWhatItIsInstead() {
        let refused: [(String, String)] = [
            // The same login with a key still in play: the key would be billed (live, 2.1.283).
            (#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","#
                + #""apiKeySource":"ANTHROPIC_API_KEY","email":"a@b.c"}"#,
             "it would use the API key from ANTHROPIC_API_KEY"),
            (#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","#
                + #""apiKeySource":"apiKeyHelper"}"#, "it would use the API key from apiKeyHelper"),
            (#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}"#,
             "it uses bedrock, not Anthropic's API"),
            (#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}"#,
             "it signs in with api_key, not claude.ai"),
            // Live, with an empty CLAUDE_CONFIG_DIR.
            (#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#, "it is not signed in"),
            ("Not logged in. Run claude auth login.", "'claude auth status' printed nothing TapQ can read"),
            ("", "'claude auth status' printed nothing TapQ can read"),
        ]
        for (output, why) in refused {
            XCTAssertEqual(ClaudeSubscription.status(statusOutput: output), .notSubscription(why), output)
        }
    }

    /// Only what outranks the login goes; the API path's environment is `sanitized` alone and
    /// keeps the key (`testTheChildEnvironmentPolicy`).
    func testTheSubscriptionLeavesOutOnlyTheKeyAndTheToken() {
        let environment = ["ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t",
                           "CLAUDE_CODE_OAUTH_TOKEN": "o", "ANTHROPIC_BASE_URL": "u", "PATH": "/bin"]
        XCTAssertEqual(ClaudeSubscription.login.environment(environment),
                       ["CLAUDE_CODE_OAUTH_TOKEN": "o", "ANTHROPIC_BASE_URL": "u", "PATH": "/bin"])
        XCTAssertEqual(ClaudeSubscription.login.statusArguments, ["auth", "status", "--json"])
    }

    // MARK: - Versions

    func testTheVersionIsTheFirstDottedTripleOfTheOutput() {
        XCTAssertEqual(ClaudeVersions.parse(versionOutput: "2.1.283 (Claude Code)\n"), "2.1.283")
        XCTAssertEqual(ClaudeVersions.parse(versionOutput: "claude 10.20.300.4"), "10.20.300")
        XCTAssertNil(ClaudeVersions.parse(versionOutput: "Claude Code"))
        XCTAssertNil(ClaudeVersions.parse(versionOutput: "2.1 (Claude Code)"))
    }

    /// D5: the K0-verified floor through the version the SDK typings describe.
    func testTheSupportedRange() {
        let range = ClaudeVersions.supported
        for version in ["2.1.260", "2.1.283", "2.1.293"] { XCTAssertTrue(range.contains(version), version) }
        for version in ["2.1.153", "2.1.259", "2.1.294", "2.2.0", "3.0.0"] {
            XCTAssertFalse(range.contains(version), version)
        }
        XCTAssertEqual(range.refusal(for: .claude, found: "2.1.153"),
                       "Claude Code 2.1.153 is not supported. TapQ supports 2.1.260 through 2.1.293.")
    }

    // MARK: - Executable

    func testAnOverridePathIsUsedAsGiven() throws {
        XCTAssertEqual(try ClaudeExecutable.resolve(override: " /opt/claude ",
                                                    environment: [:],
                                                    workspacePath: "/tmp"),
                       "/opt/claude")
    }

    func testAMissingExecutableIsAnErrorAtStartNotAtTheFirstMessage() {
        XCTAssertThrowsError(try ClaudeExecutable.resolve(
            override: nil,
            environment: ["PATH": "/tapq/does/not/exist"],
            workspacePath: "/tmp")) { error in
            XCTAssertEqual(error as? ClaudeLaunchError,
                           .executableNotFound(name: "claude", path: "/tapq/does/not/exist"))
        }
        XCTAssertThrowsError(try ClaudeExecutable.resolve(override: "   ",
                                                          environment: [:],
                                                          workspacePath: "/tmp"))
    }
}
