import Foundation
import TapQContracts
import TapQKernel

/// Frames in; events and reply lines out, by the §7.1 table, with the little state that
/// needs: whether the session has started, and every request still open, in arrival order.
///
/// Not an actor and not `Sendable`: `ClaudeDelegate` owns one, touches it only on the main
/// actor, and writes the replies. Kept apart from the process so every rule is tested
/// without spawning anything.
public final class ClaudeFrameMapper {
    public struct Output: Equatable {
        public var events: [DelegateEvent] = []
        /// Lines for Claude Code's stdin, in order.
        public var replies: [String] = []

        public init(events: [DelegateEvent] = [], replies: [String] = []) {
            self.events = events
            self.replies = replies
        }
    }

    private struct OpenRequest {
        let id: String
        let toolUseID: String?
        let inputJSON: String
        /// `permission_suggestions` scoped to this session; nil when "don't ask again" is not offered.
        let alwaysAllowJSON: String?
        let questions: [Question]?
    }

    static let withdrawnLimit = 64

    private let sessionID: String
    private let version: String?
    private let allowsUnsupportedVersion: Bool
    private let diagnostics: TapQDiagnosticEmitter
    private var started = false
    private var open: [OpenRequest] = []
    /// The last `withdrawnLimit` requests the CLI withdrew. A reply to one is dropped, as the
    /// protocol says a late reply is ignored: the kernel may decide on a request in the
    /// moment it is withdrawn.
    private var withdrawn: [String] = []
    /// The `tool_use` ids of the last `withdrawnLimit` requests TapQ denied: their
    /// `tool_result` is an error that only says the user said no, so the step was declined.
    private var denied: [String] = []
    /// Tool calls running as tasks whose `task_notification` has not come. A `tool_result`
    /// for one of them is a command moved to the background (`run_in_background`, or past its
    /// timeout): it runs on, and its step ends with the notification (2026-10-15).
    private var openTasks: [String] = []
    /// Of those, the ones whose `tool_result` came first.
    private var backgrounded: [String] = []

    /// `sessionID` is the id persisted before the spawn, which the first `system/init` must
    /// report. Its Claude Code version must be in `ClaudeVersions.supported` unless
    /// `allowsUnsupportedVersion` (D5); one other than `version`, the one the startup check
    /// accepted, is an auto-update, logged and accepted.
    public init(sessionID: String, version: String? = nil, allowsUnsupportedVersion: Bool = false,
                diagnostics: TapQDiagnosticEmitter = TapQDiagnosticEmitter(category: "delegate.claude")) {
        self.sessionID = sessionID
        self.version = version
        self.allowsUnsupportedVersion = allowsUnsupportedVersion
        self.diagnostics = diagnostics
    }

    public func map(_ frame: ClaudeFrame) -> Output {
        switch frame {
        case .systemInit(let reported, let reportedVersion, let apiKeySource, let permissionMode):
            // One per turn that starts (K0); only the first says anything about the session.
            guard !started else { return Output() }
            started = true
            // What the process bills ("none" is its own login, `--subscription claude`), and the
            // mode it really runs in (an unavailable `auto` starts as `manual`).
            diagnostics.record("claude.init", fields: ["apiKeySource": apiKeySource ?? "unknown",
                                                       "permissionMode": permissionMode ?? "unknown"])
            if reported != sessionID {
                return Output(events: [.violation(
                    "system/init reports session \(reported), not the persisted \(sessionID)")])
            }
            guard let reportedVersion else { return Output() }
            guard allowsUnsupportedVersion || ClaudeVersions.supported.contains(reportedVersion) else {
                return Output(events: [.violation(
                    ClaudeVersions.supported.refusal(for: .claude, found: reportedVersion))])
            }
            if let version, reportedVersion != version {
                diagnostics.record("claude.version_changed", level: .warning,
                                   fields: ["from": version, "to": reportedVersion])
            }
            return Output()

        case .assistant(let said, let toolUses):
            return Output(events: said.map { .said($0) }
                + toolUses.map { .progress(Self.progressLine($0), step: $0.id) })

        case .toolResults(let results):
            return Output(events: results.compactMap { result in
                if openTasks.contains(result.toolUseID) {
                    Self.append(result.toolUseID, to: &backgrounded)
                    diagnostics.record("tool.backgrounded")
                    return nil
                }
                let outcome: StepOutcome = result.notExecuted || denied.contains(result.toolUseID) ? .declined
                    : result.isError ? .failed : .done
                return .stepEnded(step: result.toolUseID, outcome)
            })

        case .taskStarted(let toolUseID):
            Self.append(toolUseID, to: &openTasks)
            return Output()

        case .taskEnded(let toolUseID, let status):
            openTasks.removeAll { $0 == toolUseID }
            guard let index = backgrounded.firstIndex(of: toolUseID) else { return Output() }
            backgrounded.remove(at: index)
            let outcome: StepOutcome = status == "completed" ? .done : status == "stopped" ? .stopped : .failed
            return Output(events: [.stepEnded(step: toolUseID, outcome)])

        case .result(let result):
            // §3.1: no request outlives its turn.
            let events = open.map { DelegateEvent.withdrawn(requestID: $0.id) }
            open.map(\.id).forEach(remember)
            open.removeAll()
            return Output(events: events + [Self.terminal(result)])

        case .canUseTool(let request):
            return Output(events: [accept(request)])

        case .elicitation(let requestID, let server):
            return Output(events: [.notice(Self.elicitationNotice(server: server))],
                          replies: [StreamJSONCodec.encodeElicitationDecline(requestID: requestID)])

        case .unsupportedControl(let requestID, let subtype):
            return Output(replies: [StreamJSONCodec.encodeControlError(
                requestID: requestID, message: "TapQ does not handle \(subtype)")])

        case .cancel(let requestID):
            guard let index = open.firstIndex(where: { $0.id == requestID }) else { return Output() }
            open.remove(at: index)
            remember(requestID)
            return Output(events: [.withdrawn(requestID: requestID)])

        case .violation(let detail):
            return Output(events: [.violation(detail)])

        case .permissionDenied(let tool, let reasonType):
            // Its auto mode's classifier said no out of the user's hearing: the user is told.
            // Any other denial (a deny rule) is the user's own setting, and only logged.
            guard reasonType == "classifier" else { return Output() }
            return Output(events: [.notice(Self.autoModeBlocked(tool))])

        case .ignored:
            return Output()
        }
    }

    /// `--auto-mode`: what Claude Code's classifier stopped, in words.
    static func autoModeBlocked(_ tool: String) -> String {
        let action: String
        switch tool {
        case "Bash": action = "running a command"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": action = "changing a file"
        case "WebFetch": action = "fetching a web page"
        case "WebSearch": action = "searching the web"
        default: action = "using \(tool)"
        }
        return "Claude Code's auto mode blocked it from \(action)."
    }

    private static func append(_ id: String, to list: inout [String]) {
        list.append(id)
        if list.count > withdrawnLimit { list.removeFirst() }
    }

    private func remember(_ withdrawnID: String) {
        withdrawn.append(withdrawnID)
        if withdrawn.count > Self.withdrawnLimit { withdrawn.removeFirst() }
    }

    /// The reply that resolves a permission request; nil when the CLI already withdrew it.
    ///
    /// Allow echoes the input verbatim. "Always" adds the request's own suggestions, scoped
    /// to this session, so a spoken "don't ask again" never writes the user's settings
    /// files. A request that offered none is simply allowed.
    public func reply(toPermission id: String, _ decision: PermissionDecision) throws -> String? {
        guard let request = try take(id) else { return nil }
        switch decision {
        case .allow(let always):
            return StreamJSONCodec.encodeAllow(requestID: id,
                                               updatedInputJSON: request.inputJSON,
                                               updatedPermissionsJSON: always ? request.alwaysAllowJSON : nil)
        case .deny(let feedback):
            if let toolUseID = request.toolUseID {
                denied.append(toolUseID)
                if denied.count > Self.withdrawnLimit { denied.removeFirst() }
            }
            return StreamJSONCodec.encodeDeny(requestID: id, message: feedback ?? "The user said no.")
        }
    }

    /// The reply that answers a question request; nil when the CLI already withdrew it.
    /// `answers[i]` answers question i: its labels are joined with ", ", the separator
    /// AskUserQuestion documents for multi-select (unverified live).
    public func reply(toQuestion id: String, answers: [[String]]) throws -> String? {
        if withdrawn.contains(id) { return nil }
        guard let request = open.first(where: { $0.id == id }) else {
            throw ClaudeDelegateError.unknownRequest(id)
        }
        guard let questions = request.questions,
              let questionsJSON = JSONText.rawMember("questions", of: request.inputJSON[...]) else {
            throw ClaudeDelegateError.notAQuestion(id)
        }
        guard answers.count == questions.count else {
            throw ClaudeDelegateError.answerCount(id, expected: questions.count, got: answers.count)
        }
        _ = try take(id)
        return StreamJSONCodec.encodeQuestionAnswer(
            requestID: id,
            questionsJSON: String(questionsJSON),
            answers: zip(questions, answers).map { ($0.key, $1.joined(separator: ", ")) })
    }

    // MARK: - Rules

    private func accept(_ request: ClaudeToolRequest) -> DelegateEvent {
        let alwaysAllow = request.suppressAlwaysAllow ? nil
            : request.suggestionsJSON.flatMap(Self.sessionScoped)
        open.append(OpenRequest(id: request.requestID,
                                toolUseID: request.toolUseID,
                                inputJSON: request.inputJSON,
                                alwaysAllowJSON: alwaysAllow?.payloadJSON,
                                questions: request.questions))
        if let questions = request.questions {
            return .question(QuestionRequest(id: request.requestID, questions: questions))
        }
        let input = JSONText.parse(request.inputJSON)
        return .permission(PermissionRequest(
            id: request.requestID,
            tool: request.toolName,
            inputJSON: request.inputJSON,
            command: input?["command"]?.stringValue,
            paths: ["file_path", "notebook_path"].compactMap { input?[$0]?.stringValue },
            title: request.title,
            reason: request.reason.flatMap { Self.boilerplateReasons.contains($0) ? nil : $0 },
            alwaysAllow: alwaysAllow,
            step: request.toolUseID))
    }

    /// Reasons that say only that a prompt is a prompt: live, every acceptEdits Bash request
    /// carried the first, and reading it aloud added nothing.
    static let boilerplateReasons: Set<String> = ["This command requires approval"]

    private func take(_ id: String) throws -> OpenRequest? {
        if withdrawn.contains(id) { return nil }
        guard let index = open.firstIndex(where: { $0.id == id }) else {
            throw ClaudeDelegateError.unknownRequest(id)
        }
        return open.remove(at: index)
    }

    /// Every abort is the interrupt TapQ sent (02-2); any other error result is a failed turn
    /// on a healthy process, reported with the first reason Claude Code gave (02-5, D6).
    /// `[ede_diagnostic]` entries are the CLI's internal diagnostics, not a reason to speak.
    static func terminal(_ result: ClaudeResult) -> DelegateEvent {
        if result.terminalReason?.hasPrefix("aborted_") == true { return .stopped }
        guard result.isError else { return .finished(text: result.text ?? "") }
        let errors = result.errors.filter { !$0.hasPrefix(diagnosticErrorPrefix) }
        let given = [result.text ?? "", errors.joined(separator: "; ")]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return .failed(reason: given
            ?? result.terminalReason.map { "\(result.subtype) (\($0))" }
            ?? result.subtype)
    }

    static let diagnosticErrorPrefix = "[ede_diagnostic]"

    /// The declined elicitation, said out loud.
    static func elicitationNotice(server: String) -> String {
        "\(AgentID.claude.displayName)'s \(server) server asked for input; I declined."
    }

    /// The suggestions with every `destination` rewritten to `"session"` (research §2.3).
    static func sessionScoped(_ suggestionsJSON: String) -> AlwaysAllowOffer? {
        guard let suggestions = JSONText.parse(suggestionsJSON)?.arrayValue, !suggestions.isEmpty else {
            return nil
        }
        let scoped = suggestions.map { suggestion -> JSONValue in
            guard var members = suggestion.objectValue else { return suggestion }
            members["destination"] = .string("session")
            return .object(members)
        }
        let described = scoped.map(describe).joined(separator: "; ")
        return AlwaysAllowOffer(description: "\(described) for this session",
                                payloadJSON: JSONText.serialize(.array(scoped)))
    }

    /// "allow Bash(npm test:*)", "acceptEdits mode", "access to /tmp".
    private static func describe(_ suggestion: JSONValue) -> String {
        let type = suggestion["type"]?.stringValue ?? "update"
        switch type {
        case "addRules", "replaceRules":
            let rules = (suggestion["rules"]?.arrayValue ?? []).map { rule -> String in
                let tool = rule["toolName"]?.stringValue ?? "?"
                return rule["ruleContent"]?.stringValue.map { "\(tool)(\($0))" } ?? tool
            }
            return "\(suggestion["behavior"]?.stringValue ?? "allow") \(rules.joined(separator: ", "))"
        case "setMode":
            return "\(suggestion["mode"]?.stringValue ?? "?") mode"
        case "addDirectories":
            let directories = suggestion["directories"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return "access to \(directories.joined(separator: ", "))"
        default:
            return type
        }
    }

    // MARK: - Progress

    /// "Bash: Run the unit tests": the tool and its primary argument in full. For status only;
    /// whitespace runs become single spaces so it stays one line.
    static func progressLine(_ toolUse: ClaudeToolUse) -> String {
        guard let argument = primaryArgument(toolUse) else { return toolUse.name }
        return "\(toolUse.name): \(argument)"
    }

    /// The argument that says what the tool is about to do. Anything not listed falls back
    /// to `description`, then to the first string field in sorted key order. A Bash call is
    /// its `description`, the words Claude Code itself shows for it ("Running <description>"),
    /// and its command only when it has none (2026-10-15).
    static let primaryArgumentKeys: [String: [String]] = [
        "Bash": ["description", "command"],
        "Read": ["file_path"],
        "Edit": ["file_path"],
        "Write": ["file_path"],
        "NotebookEdit": ["notebook_path", "file_path"],
        "Grep": ["pattern"],
        "Glob": ["pattern"],
        "Agent": ["description", "prompt"],
        "Task": ["description", "prompt"],
        "WebSearch": ["query"],
        "WebFetch": ["url"],
    ]

    private static func primaryArgument(_ toolUse: ClaudeToolUse) -> String? {
        guard let input = JSONText.parse(toolUse.inputJSON)?.objectValue else { return nil }
        let keys = (primaryArgumentKeys[toolUse.name] ?? []) + ["description"] + input.keys.sorted()
        return keys.lazy
            .compactMap { input[$0]?.stringValue?.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
    }
}
