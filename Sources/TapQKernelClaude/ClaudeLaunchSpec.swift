import Foundation
import TapQContracts
import TapQKernel

/// The permission modes the kernel will start Claude Code in, by their `--permission-mode`
/// spelling: the one list every TapQ command line parses through.
///
/// `acceptEdits` is the product; `manual`, where Claude Code asks for everything, stays for
/// testing (`claude` 2.1.260 has no `default`, K0). `dontAsk` denies inside the CLI whatever
/// would prompt, which suits a job with nobody listening: it can
/// refuse on the user's behalf but never approve. `auto` (opt-in, `--auto-mode`, 2026-10-12)
/// lets Claude Code's own classifier approve what it judges safe and block the rest, out of
/// the user's hearing; what it still asks (an `ask` rule, a question, a pause after repeated
/// blocks) comes to TapQ as before. `plan` is not offered. `bypassPermissions` approves
/// everything, so approve and deny would be dead verbs (D2); `parse` refuses it by name.
public enum ClaudePermissionMode: String, Sendable, Equatable, CaseIterable {
    case acceptEdits
    case manual
    case dontAsk
    case auto

    public static let standard: ClaudePermissionMode = .acceptEdits

    /// The `--permission-mode` value, which is the case name.
    public var argumentValue: String { rawValue }

    /// The refusal is a distinct error so the executable can say why rather than "unknown mode".
    /// `auto` is refused by name too: `--auto-mode` is its one switch, for both agents.
    public static func parse(_ raw: String) throws -> ClaudePermissionMode {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "bypassPermissions" {
            throw ClaudeLaunchError.refusedPermissionMode(trimmed)
        }
        if trimmed == ClaudePermissionMode.auto.rawValue {
            throw ClaudeLaunchError.autoModeIsAFlag
        }
        guard let mode = ClaudePermissionMode(rawValue: trimmed) else {
            throw ClaudeLaunchError.unknownPermissionMode(trimmed)
        }
        return mode
    }
}

public enum ClaudeLaunchError: Error, Equatable, CustomStringConvertible {
    case refusedPermissionMode(String)
    case unknownPermissionMode(String)
    /// `--permission-mode auto`: `--auto-mode` sets it, with Codex's reviewer.
    case autoModeIsAFlag
    case executableNotFound(name: String, path: String?)

    public var description: String {
        switch self {
        case .refusedPermissionMode(let mode):
            return "permission mode '\(mode)' is refused: it answers permission requests "
                + "inside the CLI, so approve and deny would never be asked for"
        case .unknownPermissionMode(let mode):
            return "unknown permission mode '\(mode)'; expected one of "
                + ClaudePermissionMode.allCases.filter { $0 != .auto }.map(\.rawValue).joined(separator: ", ")
        case .autoModeIsAFlag:
            return "auto mode is set with --auto-mode, which also lets Codex's reviewer approve"
        case .executableNotFound(let name, let path):
            return "'\(name)' is not on PATH (\(path ?? "PATH unset"))"
        }
    }
}

/// The argv for one `claude` subprocess, and nothing else. Pure so the whole command line
/// is asserted in a test rather than discovered on hardware.
public struct ClaudeLaunchSpec: Sendable, Equatable {
    /// Exactly one of the two, by construction: `--session-id` and `--resume` are mutually
    /// exclusive (K0 07-resume passed `--resume` alone and got the same session id back).
    public enum Session: Sendable, Equatable {
        case fresh(UUID)
        case resume(String)
    }

    /// `user` keeps the user's own settings and `project` the workspace's; `local` is where
    /// Claude Code writes "don't ask again" rules, so they take effect (02-12).
    public static let defaultSettingSources: [String] = ["user", "project", "local"]

    /// The model TapQ starts Claude Code on, whatever the user's settings name (maintainer,
    /// 2026-10-11): `--model` outranks every settings file.
    public static let defaultModel = "claude-haiku-5-5"
    public static let modelEnvironmentKey = "TAPQ_CLAUDE_MODEL"

    /// `TAPQ_CLAUDE_MODEL` when set and non-blank, else ``defaultModel``.
    public static func resolvedModel(environment: [String: String]) -> String {
        let override = environment[modelEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? defaultModel : override
    }

    public let executablePath: String
    public let workspace: URL
    public let permissionMode: ClaudePermissionMode
    /// `nil` omits `--setting-sources` entirely, which is the CLI's own default (every
    /// source). An empty array omits it too; there is no such thing as "no sources".
    public let settingSources: [String]?
    /// `--model`; `nil` leaves the choice to the settings.
    public let model: String?
    public let session: Session

    public init(executablePath: String,
                workspace: URL,
                permissionMode: ClaudePermissionMode = .standard,
                settingSources: [String]? = ClaudeLaunchSpec.defaultSettingSources,
                model: String? = nil,
                session: Session) {
        self.executablePath = executablePath
        self.workspace = workspace
        self.permissionMode = permissionMode
        self.settingSources = settingSources
        self.model = model
        self.session = session
    }

    /// No `--include-partial-messages`: the MVP relays whole assistant messages, and K0
    /// measured what that costs (an interrupt cannot bite during prose, only during tools).
    public var arguments: [String] {
        var argv = [
            "--print", "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", permissionMode.argumentValue,
        ]
        if let model, !model.isEmpty {
            argv += ["--model", model]
        }
        switch session {
        case .fresh(let id):
            // Lowercased because that is the spelling the CLI reports back in
            // `system/init.session_id`, and the kernel compares the two.
            argv += ["--session-id", id.uuidString.lowercased()]
        case .resume(let id):
            argv += ["--resume", id]
        }
        if let settingSources, !settingSources.isEmpty {
            argv += ["--setting-sources", settingSources.joined(separator: ",")]
        }
        return argv
    }
}

/// Where the `claude` binary is. Resolved once, at start, from `PATH`.
public enum ClaudeExecutable {
    public static let name = "claude"

    /// An override is taken as given — the operator named a path, so TapQ does not
    /// second-guess it; a bad one fails at `run()` with the OS's own message.
    public static func resolve(override: String?,
                               environment: [String: String],
                               workspacePath: String) throws -> String {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let resolved = OwnedSessionExecutable.resolve(
            named: name, environment: environment, workingDirectoryPath: workspacePath)
        else {
            throw ClaudeLaunchError.executableNotFound(name: name, path: environment["PATH"])
        }
        return resolved
    }
}

/// The environment the delegate is spawned into (02-7, 08-2).
///
/// Removed: every `TAPQ_*` and `OPENAI_API_KEY`, which are TapQ's and would otherwise reach
/// every tool, script and MCP server Claude runs; and the variables by which a Claude Code
/// session tells its children who they are, so a kernel launched from inside a Claude Code
/// session does not start a child that believes it is nested. That list is the 2.1.283
/// binary's own: what it sets for its children (`CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`,
/// `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_PID`), what it deletes
/// before starting a session of its own (adding `CLAUDE_CODE_BRIDGE_SESSION_ID`), and the
/// host and IDE links (`CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SSE_PORT`,
/// `CLAUDE_CODE_HOST_SESSION_ID`). The Python SDK removes only `CLAUDECODE`.
///
/// Everything else stays, the user's Claude authentication above all:
/// `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_*`.
public enum ClaudeEnvironment {
    public static let removedNames: Set<String> = [
        "OPENAI_API_KEY",
        "CLAUDECODE", "CLAUDE_PID",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_HOST_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
    ]

    public static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !removedNames.contains(key) && !key.hasPrefix("TAPQ_") }
    }
}

/// Claude Code on the user's claude.ai subscription (`--subscription claude`).
///
/// In Claude Code's order an API key or auth token in the environment outranks the claude.ai
/// login, so both are left out. `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) stays: it
/// is a subscription credential. Cloud providers and an `apiKeyHelper` are not stripped;
/// they are deliberate, and `claude auth status` reports them, which refuses.
public enum ClaudeSubscription {
    public static let login = SubscriptionLogin(
        overridingVariables: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
        statusArguments: ["auth", "status", "--json"],
        loginCommand: "claude auth login",
        parse: status(statusOutput:))

    /// `claude auth status --json` (2.1.283; undocumented, read defensively): a claude.ai
    /// login on Anthropic's own API with no API key in play is the subscription; anything
    /// else is not, and says what it is instead.
    public static func status(statusOutput: String) -> SubscriptionStatus {
        guard let status = JSONText.parse(statusOutput), status["loggedIn"] != nil else {
            return .notSubscription("'claude auth status' printed nothing TapQ can read")
        }
        guard status["loggedIn"]?.boolValue == true else {
            return .notSubscription("it is not signed in")
        }
        if let source = status["apiKeySource"]?.stringValue {
            return .notSubscription("it would use the API key from \(source)")
        }
        if let provider = status["apiProvider"]?.stringValue, provider != "firstParty" {
            return .notSubscription("it uses \(provider), not Anthropic's API")
        }
        guard status["authMethod"]?.stringValue == "claude.ai" else {
            let method = status["authMethod"]?.stringValue ?? "no method"
            return .notSubscription("it signs in with \(method), not claude.ai")
        }
        return .account(SubscriptionAccount(method: "claude.ai",
                                            plan: status["subscriptionType"]?.stringValue))
    }
}

/// The Claude Code versions TapQ supports (D5). The floor is the version K0 verified; the
/// cap is the one the current Agent SDK typings describe (research §2.7). Raising the cap
/// after a K0-style check is a one-line change.
public enum ClaudeVersions {
    public static let supported = VersionRange(floor: "2.1.260", cap: "2.1.293")

    /// "2.1.283 (Claude Code)" → "2.1.283": the first dotted triple, as the Python SDK reads it.
    public static func parse(versionOutput: String) -> String? {
        guard let match = versionOutput.firstMatch(of: versionPattern) else { return nil }
        return String(versionOutput[match.range])
    }

    private static let versionPattern = try! Regex(#"[0-9]+\.[0-9]+\.[0-9]+"#)
}
