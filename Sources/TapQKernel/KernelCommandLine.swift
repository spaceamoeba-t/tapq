import Foundation

/// Everything the operator can get wrong before anything has started.
///
/// Not a `FatalReason`: nothing has started, so there is nothing to crash and nothing to
/// log. It is printed to standard error and the process exits `EX_USAGE` (64). For a host
/// that is a bug in the argv it built.
public enum KernelUsageError: Error, Equatable, CustomStringConvertible {
    case missingSubcommand
    case missingValue(flag: String)
    case unknownFlag(String)
    case unexpectedArgument(String)
    case missingWorkspace
    case relativeWorkspace(String)
    case refusedPermissionMode(String)
    case unknownPermissionMode(String)
    case emptySettingSources
    case unknownAudio(String)
    case invalidRealtimeEndpoint(String)
    case invalidOpenAIBaseURL(String)
    case invalidLanguage(String)
    case unknownAgent(String)
    /// `--desktop-chat` or `--api-chat` naming something that is not a chat agent.
    case unknownChatAgent(flag: String, String)
    /// One chat agent named by both `--desktop-chat` and `--api-chat`.
    case chatInBothBackends(String)
    /// `--agents` naming something that is not an agent.
    case unknownPlanAgent(String)
    /// `--auto-mode` with `--permission-mode` naming anything but `auto`.
    case autoModeWithPermissionMode(String)
    case workspaceMissing(path: String)
    case workspaceNotADirectory(path: String)
    case directoryOperationFailed(detail: String)

    public var description: String {
        switch self {
        case .missingSubcommand:
            return "expected a subcommand: run or clear"
        case .missingValue(let flag):
            return "\(flag) needs a value"
        case .unknownFlag(let flag):
            return "unknown option '\(flag)'"
        case .unexpectedArgument(let argument):
            return "unexpected argument '\(argument)'"
        case .missingWorkspace:
            return "--workspace is required"
        case .relativeWorkspace(let path):
            return "--workspace needs an absolute path, not '\(path)'"
        case .refusedPermissionMode(let mode):
            return "permission mode '\(mode)' is refused: it answers permission requests "
                + "inside the CLI, so approve and deny would never be asked for"
        case .unknownPermissionMode(let mode):
            return "unknown permission mode '\(mode)'; see --help"
        case .emptySettingSources:
            return "--setting-sources needs at least one source"
        case .unknownAudio(let value):
            return "--audio takes 'on' or 'off', not '\(value)'"
        case .invalidRealtimeEndpoint(let value):
            return "--realtime-endpoint needs a ws:// or wss:// URL, not '\(value)'"
        case .invalidOpenAIBaseURL(let value):
            return "--openai-base-url needs an http:// or https:// URL, not '\(value)'"
        case .invalidLanguage(let value):
            return "--language needs an ISO-639-1 code such as en, or auto, not '\(value)'"
        case .unknownAgent(let value):
            return "--subscription takes agent names ("
                + AgentID.allCases.filter { $0.kind == .coding }.map(\.rawValue).joined(separator: ", ")
                + "), not '\(value)'"
        case .unknownChatAgent(let flag, let value):
            return "\(flag) takes chat agent names ("
                + AgentID.allCases.filter { $0.kind == .chat }.map(\.rawValue).joined(separator: ", ")
                + "), not '\(value)'"
        case .chatInBothBackends(let agent):
            return "\(agent) is named by both --desktop-chat and --api-chat; a chat is reached one way"
        case .unknownPlanAgent(let value):
            return "--agents takes agent names ("
                + AgentID.mac.map(\.rawValue).joined(separator: ", ") + "), not '\(value)'"
        case .autoModeWithPermissionMode(let mode):
            return "--auto-mode runs Claude Code in its auto mode, so it cannot be combined with "
                + "--permission-mode \(mode)"
        case .workspaceMissing(let path):
            return "no such directory: \(path)"
        case .workspaceNotADirectory(let path):
            return "not a directory: \(path)"
        case .directoryOperationFailed(let detail):
            return detail
        }
    }
}

/// `tapq-kernel run`'s options, parsed and nothing else.
///
/// Pure on purpose: whether the workspace exists is `KernelWorkspacePreparation`'s question,
/// one call later, so the grammar can be asserted without a disk. Whether this run resumes
/// is not a flag at all: a journal present means resume (§4.9).
public struct KernelCommandLine: Equatable, Sendable {
    public enum Invocation: Equatable, Sendable {
        case help
        case run(KernelCommandLine)
        case clear(workspace: URL)
    }

    /// The ISO-639-1 code the speech-to-text session is told to expect (research §3:
    /// `transcription.language`). Without one the service guesses, and on 2026-09-20 it
    /// guessed a dozen languages for twelve minutes of English.
    public static let defaultLanguage = "en"
    /// `--language auto`: no code at all, so the service tells the language of each utterance
    /// itself, for a user who mixes two (Chinese and English, say). Opt-in only, for the drift
    /// above.
    public static let automaticLanguage = "auto"

    public let workspace: URL
    /// As typed, or `nil` for `ClaudePermissionMode.standard`. Not judged here: the mode list
    /// is the Claude adapter's, which this target sits below.
    public let permissionMode: String?
    /// `nil` is the service's own endpoint; anything else is a peer that speaks the same wire.
    public let realtimeEndpoint: URL?
    /// `nil` is `https://api.openai.com/v1`, where the intent model and the summarizer are asked.
    public let openAIBaseURL: URL?
    /// `nil` for `auto`: the service is told no language.
    public let language: String?
    /// The agents that sign in with the user's own subscription instead of an API key from
    /// the environment (`SubscriptionLogin`). Empty, the default: every agent gets the
    /// environment as it is.
    public let subscriptions: Set<AgentID>
    /// Opt-in (2026-10-12): Claude Code in its `auto` permission mode and Codex's approvals
    /// reviewed by its `auto_review` agent, so each agent approves what it judges safe and
    /// asks the user only for the rest.
    public let autoMode: Bool
    /// Opt-in (2026-10-13): the chat agents TapQ may drive in the user's Claude and ChatGPT
    /// apps through Accessibility. Empty, the default: neither.
    public let desktopChats: Set<AgentID>
    /// Opt-in (2026-10-13): the chat agents TapQ keeps as its own chats over the vendors' APIs,
    /// on `TAPQ_ANTHROPIC_API_KEY` and `TAPQ_OPENAI_API_KEY`. Never one of `desktopChats`.
    /// Empty, the default: neither.
    public let apiChats: Set<AgentID>
    /// The agents `--agents` names: any other is never probed or started, and is answered
    /// "isn't turned on in TapQ". `nil`, the default: every agent.
    public let planAgents: Set<AgentID>?

    /// How each chat agent turned on is reached.
    public var chatBackends: [AgentID: ChatBackend] {
        Dictionary(uniqueKeysWithValues: desktopChats.map { ($0, ChatBackend.app) } + apiChats.map { ($0, .api) })
    }

    public init(workspace: URL,
                permissionMode: String? = nil,
                realtimeEndpoint: URL? = nil,
                openAIBaseURL: URL? = nil,
                language: String? = KernelCommandLine.defaultLanguage,
                subscriptions: Set<AgentID> = [],
                autoMode: Bool = false,
                desktopChats: Set<AgentID> = [],
                apiChats: Set<AgentID> = [],
                planAgents: Set<AgentID>? = nil) {
        self.workspace = workspace
        self.permissionMode = permissionMode
        self.realtimeEndpoint = realtimeEndpoint
        self.openAIBaseURL = openAIBaseURL
        self.language = language
        self.subscriptions = subscriptions
        self.autoMode = autoMode
        self.desktopChats = desktopChats
        self.apiChats = apiChats
        self.planAgents = planAgents
    }

    public static let usage = """
        tapq-kernel — speak to Claude Code and Codex, and hear them back.

        USAGE
          tapq-kernel run --workspace <abs-dir> [--language <code>|auto]
                          [--permission-mode acceptEdits|manual] [--subscription claude]
                          [--auto-mode] [--agents <agents>]
                          [--realtime-endpoint <ws-url>] [--openai-base-url <http-url>]
          tapq-kernel clear --workspace <abs-dir>
          tapq-kernel --help

        SUBCOMMANDS
          run    Listen and relay until standard input closes, SIGINT, SIGTERM or
                 SIGHUP. Resumes the workspace's journal when there is one. Status lines
                 go to standard output; diagnostics to standard error.
          clear  Delete what TapQ kept for the workspace: its journal, session ids and
                 diagnostics. Refused while a kernel runs for it. The agents' own session
                 history is theirs and is not touched.

        OPTIONS
          --workspace <abs-dir>       The directory the agents work in. Required.
          --language <code>|auto      The ISO-639-1 code of the language the user speaks
                                      (default: en). 'auto' tells the service none, so it
                                      hears each utterance in whatever language it is: for
                                      a user who mixes two.
          --permission-mode <mode>    How Claude Code asks (default: acceptEdits).
                                      bypassPermissions is refused.
          --subscription <agents>     Comma-separated agents that use their own CLI's
                                      subscription login, not an API key from the
                                      environment: claude (claude.ai). Checked at start.
          --auto-mode                 Let each agent approve what it judges safe: Claude
                                      Code in its auto permission mode, Codex's approvals
                                      reviewed by its auto_review agent. What they still
                                      ask, TapQ asks you. Off by default.
          --agents <agents>           Comma-separated agents this run may start: claude,
                                      codex. Any other is never started, and is answered
                                      "isn't turned on in TapQ". All by default.
          --realtime-endpoint <url>   A ws:// or wss:// URL for the speech sessions instead
                                      of the service's own.
          --openai-base-url <url>     An http:// or https:// base URL for the text models
                                      instead of https://api.openai.com/v1.
          --help                      Print this and exit.
        """

    public static func parse(_ arguments: [String]) throws -> Invocation {
        // Asked before anything is judged: somebody who typed a flag wrong is exactly the
        // person reaching for `--help`.
        if arguments.contains("--help") || arguments.contains("-h") { return .help }

        guard let subcommand = arguments.first else { throw KernelUsageError.missingSubcommand }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "run":
            return .run(try parseRun(rest))
        case "clear":
            return .clear(workspace: try parseClear(rest))
        default:
            if subcommand.hasPrefix("-") { throw KernelUsageError.missingSubcommand }
            throw KernelUsageError.unexpectedArgument(subcommand)
        }
    }

    private static func parseRun(_ arguments: [String]) throws -> KernelCommandLine {
        var workspace: URL?
        var permissionMode: String?
        var realtimeEndpoint: URL?
        var openAIBaseURL: URL?
        var language: String? = defaultLanguage
        var subscriptions: Set<AgentID> = []
        var autoMode = false
        var desktopChats: Set<AgentID> = []
        var apiChats: Set<AgentID> = []
        var planAgents: Set<AgentID>?

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--workspace":
                workspace = try absoluteWorkspace(value(for: argument, from: arguments, at: &index))
            case "--permission-mode":
                permissionMode = try value(for: argument, from: arguments, at: &index)
            case "--realtime-endpoint":
                let raw = try value(for: argument, from: arguments, at: &index)
                guard let url = url(raw, schemes: ["ws", "wss"]) else {
                    throw KernelUsageError.invalidRealtimeEndpoint(raw)
                }
                realtimeEndpoint = url
            case "--openai-base-url":
                let raw = try value(for: argument, from: arguments, at: &index)
                guard let url = url(raw, schemes: ["http", "https"]) else {
                    throw KernelUsageError.invalidOpenAIBaseURL(raw)
                }
                openAIBaseURL = url
            case "--language":
                let raw = try value(for: argument, from: arguments, at: &index)
                guard raw == automaticLanguage
                        || (raw.count == 2 && raw.allSatisfy({ $0.isASCII && $0.isLowercase })) else {
                    throw KernelUsageError.invalidLanguage(raw)
                }
                language = raw == automaticLanguage ? nil : raw
            case "--subscription":
                let raw = try value(for: argument, from: arguments, at: &index)
                for name in raw.split(separator: ",", omittingEmptySubsequences: false) {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    // A chat agent is always the app's own account; only a CLI picks a login.
                    guard let agent = AgentID(rawValue: trimmed), agent.kind == .coding else {
                        throw KernelUsageError.unknownAgent(trimmed)
                    }
                    subscriptions.insert(agent)
                }
            case "--auto-mode":
                autoMode = true
            case "--desktop-chat":
                desktopChats.formUnion(try chatAgents(argument, value(for: argument, from: arguments, at: &index)))
            case "--api-chat":
                apiChats.formUnion(try chatAgents(argument, value(for: argument, from: arguments, at: &index)))
            case "--agents":
                let raw = try value(for: argument, from: arguments, at: &index)
                var named = planAgents ?? []
                for name in raw.split(separator: ",", omittingEmptySubsequences: false) {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard let agent = AgentID(rawValue: trimmed), AgentID.mac.contains(agent) else {
                        throw KernelUsageError.unknownPlanAgent(trimmed)
                    }
                    named.insert(agent)
                }
                planAgents = named
            default:
                throw unexpected(argument)
            }
        }

        guard let workspace else { throw KernelUsageError.missingWorkspace }
        if let both = AgentID.allCases.first(where: { desktopChats.contains($0) && apiChats.contains($0) }) {
            throw KernelUsageError.chatInBothBackends(both.rawValue)
        }
        return KernelCommandLine(workspace: workspace,
                                 permissionMode: permissionMode,
                                 realtimeEndpoint: realtimeEndpoint,
                                 openAIBaseURL: openAIBaseURL,
                                 language: language,
                                 subscriptions: subscriptions,
                                 autoMode: autoMode,
                                 desktopChats: desktopChats,
                                 apiChats: apiChats,
                                 planAgents: planAgents)
    }

    /// `--desktop-chat`'s and `--api-chat`'s value: chat agent names, comma-separated.
    private static func chatAgents(_ flag: String, _ raw: String) throws -> Set<AgentID> {
        var agents: Set<AgentID> = []
        for name in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard let agent = AgentID(rawValue: trimmed), agent.kind == .chat else {
                throw KernelUsageError.unknownChatAgent(flag: flag, trimmed)
            }
            agents.insert(agent)
        }
        return agents
    }

    private static func parseClear(_ arguments: [String]) throws -> URL {
        var workspace: URL?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            guard argument == "--workspace" else { throw unexpected(argument) }
            workspace = try absoluteWorkspace(value(for: argument, from: arguments, at: &index))
        }
        guard let workspace else { throw KernelUsageError.missingWorkspace }
        return workspace
    }

    /// Absolute only: a host app launches with cwd `/`, so a relative path would name a
    /// different folder than the one the user picked.
    private static func absoluteWorkspace(_ raw: String) throws -> URL {
        guard raw.hasPrefix("/") else { throw KernelUsageError.relativeWorkspace(raw) }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    private static func url(_ raw: String, schemes: Set<String>) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func unexpected(_ argument: String) -> KernelUsageError {
        argument.hasPrefix("-") ? .unknownFlag(argument) : .unexpectedArgument(argument)
    }

    /// Public so that another command line can parse the same way: a flag needs a value,
    /// trimmed, and empty is missing.
    public static func value(for flag: String,
                             from arguments: [String],
                             at index: inout Int) throws -> String {
        guard index < arguments.endIndex else { throw KernelUsageError.missingValue(flag: flag) }
        let raw = arguments[index]
        index += 1
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KernelUsageError.missingValue(flag: flag) }
        return trimmed
    }
}

/// The filesystem half of the command line: the workspace's kernel directory, made for `run`
/// and deleted by `clear`.
public enum KernelWorkspacePreparation {
    /// `yyyyMMdd-HHmmss`, local time, because the person reading the listing is in it.
    public static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// The workspace must be a directory; its kernel directory is created `0700` when it is
    /// not there yet. Returns the kernel directory.
    public static func prepare(_ options: KernelCommandLine,
                               supportDirectory: URL,
                               fileManager: FileManager = .default) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: options.workspace.path,
                                     isDirectory: &isDirectory) else {
            throw KernelUsageError.workspaceMissing(path: options.workspace.path)
        }
        guard isDirectory.boolValue else {
            throw KernelUsageError.workspaceNotADirectory(path: options.workspace.path)
        }
        let directory = KernelPaths.directory(supportDirectory: supportDirectory,
                                              workspace: options.workspace)
        do {
            // 0700: the journal holds what the user said to the agents, verbatim.
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: directory.path)
        } catch {
            throw KernelUsageError.directoryOperationFailed(
                detail: "could not create \(directory.path): \(error)")
        }
        return directory
    }

    /// Deletes the workspace's kernel directory: the journal, the session ids and the
    /// diagnostics with their rotated file. The workspace itself need not exist any more: a
    /// folder that is gone can still have a journal to clear. Whether a kernel is running is
    /// the caller's question.
    public static func clear(workspace: URL,
                             supportDirectory: URL,
                             fileManager: FileManager = .default) throws {
        let directory = KernelPaths.directory(supportDirectory: supportDirectory,
                                              workspace: workspace)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            throw KernelUsageError.directoryOperationFailed(
                detail: "could not delete \(directory.path): \(error)")
        }
    }
}
