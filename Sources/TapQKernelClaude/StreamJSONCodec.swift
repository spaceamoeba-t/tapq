import Foundation
import TapQContracts
import TapQKernel

/// One `tool_use` block of an `assistant` frame.
public struct ClaudeToolUse: Sendable, Equatable {
    public let name: String
    public let inputJSON: String
    /// Its `id`, which the `tool_result` that ends it names.
    public let id: String?

    public init(name: String, inputJSON: String, id: String? = nil) {
        self.name = name
        self.inputJSON = inputJSON
        self.id = id
    }
}

/// One `tool_result` block of a `user` frame: a tool call has ended (2026-10-15).
public struct ClaudeToolResult: Sendable, Equatable {
    public let toolUseID: String
    public let isError: Bool
    /// The frame's `tool_result_meta` gave it a `non_execution_kind` ("user-rejected"): it
    /// never ran.
    public let notExecuted: Bool

    public init(toolUseID: String, isError: Bool, notExecuted: Bool = false) {
        self.toolUseID = toolUseID
        self.isError = isError
        self.notExecuted = notExecuted
    }
}

/// A `result` frame: the end of one turn (research §2.5).
public struct ClaudeResult: Sendable, Equatable {
    public let subtype: String
    public let isError: Bool
    public let terminalReason: String?
    /// `result`, absent on an interrupted turn.
    public let text: String?
    /// `errors`, on the error subtypes.
    public let errors: [String]

    public init(subtype: String, isError: Bool, terminalReason: String?, text: String?,
                errors: [String] = []) {
        self.subtype = subtype
        self.isError = isError
        self.terminalReason = terminalReason
        self.text = text
        self.errors = errors
    }
}

/// A `can_use_tool` control request (research §2.3).
public struct ClaudeToolRequest: Sendable, Equatable {
    public let requestID: String
    public let toolName: String
    /// The `input` object exactly as the line carried it.
    public let inputJSON: String
    /// `description`, else `title`, else `display_name`.
    public let title: String?
    /// `decision_reason`, without ANSI escapes.
    public let reason: String?
    /// `permission_suggestions` as sent; nil when absent or empty.
    public let suggestionsJSON: String?
    public let suppressAlwaysAllow: Bool
    /// Set only when the request `requires_user_interaction` and its input has `questions`.
    public let questions: [Question]?
    /// `tool_use_id`: the `tool_use` it asks about.
    public let toolUseID: String?

    public init(requestID: String, toolName: String, inputJSON: String, title: String? = nil,
                reason: String? = nil, suggestionsJSON: String? = nil,
                suppressAlwaysAllow: Bool = false, questions: [Question]? = nil, toolUseID: String? = nil) {
        self.requestID = requestID
        self.toolName = toolName
        self.inputJSON = inputJSON
        self.title = title
        self.reason = reason
        self.suggestionsJSON = suggestionsJSON
        self.suppressAlwaysAllow = suppressAlwaysAllow
        self.questions = questions
        self.toolUseID = toolUseID
    }
}

/// One decoded stdout line, classified by the §7.1 table: strict only on what the loop acts
/// on (`system/init`, `assistant`, `result`, control requests), open for everything else.
public enum ClaudeFrame: Sendable, Equatable {
    /// `apiKeySource` is how the CLI authenticates: "none" for its own login, else the key's
    /// source ("ANTHROPIC_API_KEY", "apiKeyHelper", …). `permissionMode` is the mode it runs
    /// in: an `auto` it cannot use starts as `manual` instead (docs, 2026-10).
    case systemInit(sessionID: String, version: String?, apiKeySource: String? = nil, permissionMode: String? = nil)
    /// `system/permission_denied`: Claude Code turned a tool call down itself; `reasonType`
    /// "classifier" is its auto mode's (documented for the SDK, unverified on the CLI).
    case permissionDenied(tool: String, reasonType: String?)
    /// `said`: its text blocks, when Claude Code's model wrote them (not a subagent's, not a
    /// synthetic error or notice); its words along the way, for status (2026-10-15).
    case assistant(said: [String] = [], toolUses: [ClaudeToolUse])
    /// `user` carrying `tool_result` blocks, Claude Code's own or a subagent's: those tool
    /// calls have ended. A `user` frame without one is ignored.
    case toolResults([ClaudeToolResult])
    /// `system/task_started` for a tool call: Claude Code runs it as a task (a Bash command
    /// that takes a while, a background agent), which a `tool_result` can outlive.
    case taskStarted(toolUseID: String)
    /// `system/task_notification`: that task ended, `status` `completed`, `failed` or `stopped`
    /// (on purpose: KillShell, TaskStop).
    case taskEnded(toolUseID: String, status: String)
    case result(ClaudeResult)
    case canUseTool(ClaudeToolRequest)
    /// An MCP server asks for input.
    case elicitation(requestID: String, server: String)
    /// Any other `control_request` subtype.
    case unsupportedControl(requestID: String, subtype: String)
    /// `control_cancel_request`: the CLI withdrew one of its own requests.
    case cancel(requestID: String)
    /// Nothing for the loop to do; logged by kind at `level`. An observability frame
    /// (`keep_alive`, `tool_progress`, a `system` subtype, a `user` with no tool result, …), a `control_response`,
    /// a dialog request (never answered: TapQ declares no dialog kinds, research §2.2), or
    /// `chatter`: a line that does not start with `{`, CLI debug output (02-13).
    case ignored(kind: String, level: TapQDiagnosticEvent.Level)
    case violation(String)
}

/// The stream-json wire, both directions. Pure, portable, and the thing the tests hammer.
public enum StreamJSONCodec {
    /// How much of an unplaceable line goes into the violation detail.
    static let previewLength = 160
    /// Ignored kinds worth a warning rather than a debug line (research §2.1).
    static let warningKinds: Set<String> = [
        "chatter", "control_response/error", "control_request/request_user_dialog",
        "system/model_refusal_no_fallback", "system/mirror_error",
    ]

    // MARK: - Decoding

    public static func decode(line: String) -> ClaudeFrame {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return ignored("chatter") }
        guard let object = JSONText.parse(trimmed)?.objectValue else {
            return violation("not a JSON object", trimmed)
        }
        guard let type = object["type"]?.stringValue else {
            return violation("frame without a string 'type'", trimmed)
        }
        switch type {
        case "system": return decodeSystem(object, line: trimmed)
        case "assistant": return decodeAssistant(object, line: trimmed)
        case "user": return decodeUser(object)
        case "result": return decodeResult(object, line: trimmed)
        case "control_request": return decodeControlRequest(object, line: trimmed)
        case "control_cancel_request":
            guard let requestID = object["request_id"]?.stringValue else {
                return violation("control_cancel_request without a request_id", trimmed)
            }
            return .cancel(requestID: requestID)
        case "control_response":
            return ignored("control_response/\(object["response"]?["subtype"]?.stringValue ?? "")")
        case "conversation_reset":
            // The session id changes under TapQ, which persisted the old one.
            return .violation("Claude Code reset its conversation; TapQ cannot follow it")
        default:
            return ignored(type)
        }
    }

    private static func ignored(_ kind: String) -> ClaudeFrame {
        .ignored(kind: kind, level: warningKinds.contains(kind) ? .warning : .debug)
    }

    private static func decodeSystem(_ object: [String: JSONValue], line: String) -> ClaudeFrame {
        let subtype = object["subtype"]?.stringValue ?? ""
        if let toolUseID = object["tool_use_id"]?.stringValue {
            if subtype == "task_started" { return .taskStarted(toolUseID: toolUseID) }
            if subtype == "task_notification" {
                return .taskEnded(toolUseID: toolUseID, status: object["status"]?.stringValue ?? "")
            }
        }
        if subtype == "permission_denied" {
            return .permissionDenied(tool: object["tool_name"]?.stringValue ?? "a tool",
                                     reasonType: object["decision_reason_type"]?.stringValue)
        }
        guard subtype == "init" else { return ignored("system/\(subtype)") }
        guard let sessionID = object["session_id"]?.stringValue, !sessionID.isEmpty else {
            return violation("system/init without a session_id", line)
        }
        return .systemInit(sessionID: sessionID,
                           version: object["claude_code_version"]?.stringValue,
                           apiKeySource: object["apiKeySource"]?.stringValue,
                           permissionMode: object["permissionMode"]?.stringValue)
    }

    /// `tool_use` blocks, and the prose of Claude Code's own messages (a subagent's, with a
    /// `parent_tool_use_id`, is left out). Thinking and blocks this codec has never seen
    /// (`server_tool_use`, `redacted_thinking`, …) are not the loop's business.
    private static func decodeAssistant(_ object: [String: JSONValue], line: String) -> ClaudeFrame {
        guard let content = object["message"]?["content"]?.arrayValue else {
            return violation("assistant frame without message.content", line)
        }
        // A subagent's prose is its own; Claude Code's synthetic messages (an API error, a
        // fallback notice: model "<synthetic>") are not the agent's words.
        let ownMessage = object["parent_tool_use_id"]?.stringValue == nil
            && object["message"]?["model"]?.stringValue != "<synthetic>"
            && object["is_api_error_message"]?.boolValue != true
        var said: [String] = []
        var toolUses: [ClaudeToolUse] = []
        for block in content {
            switch block["type"]?.stringValue {
            case "text":
                if ownMessage, let text = block["text"]?.stringValue,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    said.append(text)
                }
            case "tool_use":
                guard let name = block["name"]?.stringValue,
                      let input = block["input"], input.objectValue != nil else {
                    return violation("assistant tool_use block is incomplete", line)
                }
                toolUses.append(ClaudeToolUse(name: name, inputJSON: JSONText.serialize(input),
                                              id: block["id"]?.stringValue))
            default:
                continue
            }
        }
        return .assistant(said: said, toolUses: toolUses)
    }

    /// The `tool_result` blocks, by `tool_use_id`; one without an id names no step. Nothing of
    /// the result itself is read: status never hears a tool's output.
    private static func decodeUser(_ object: [String: JSONValue]) -> ClaudeFrame {
        let content = object["message"]?["content"]?.arrayValue ?? []
        let notExecuted = Set((object["tool_result_meta"]?.arrayValue ?? []).compactMap { meta in
            meta["non_execution_kind"]?.stringValue == nil ? nil : meta["id"]?.stringValue
        })
        let results = content.compactMap { block -> ClaudeToolResult? in
            guard block["type"]?.stringValue == "tool_result",
                  let id = block["tool_use_id"]?.stringValue else { return nil }
            return ClaudeToolResult(toolUseID: id, isError: block["is_error"]?.boolValue ?? false,
                                    notExecuted: notExecuted.contains(id))
        }
        return results.isEmpty ? ignored("user") : .toolResults(results)
    }

    private static func decodeResult(_ object: [String: JSONValue], line: String) -> ClaudeFrame {
        guard let subtype = object["subtype"]?.stringValue,
              let isError = object["is_error"]?.boolValue else {
            return violation("result frame without subtype and is_error", line)
        }
        return .result(ClaudeResult(
            subtype: subtype,
            isError: isError,
            terminalReason: object["terminal_reason"]?.stringValue,
            text: object["result"]?.stringValue,
            errors: object["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []))
    }

    private static func decodeControlRequest(_ object: [String: JSONValue], line: String) -> ClaudeFrame {
        guard let requestID = object["request_id"]?.stringValue,
              let request = object["request"]?.objectValue,
              let subtype = request["subtype"]?.stringValue else {
            return violation("control_request is incomplete", line)
        }
        switch subtype {
        case "can_use_tool":
            return decodeCanUseTool(requestID: requestID, request, line: line)
        case "elicitation":
            return .elicitation(requestID: requestID,
                                server: request["mcp_server_name"]?.stringValue ?? "")
        case "request_user_dialog":
            return ignored("control_request/request_user_dialog")
        default:
            return .unsupportedControl(requestID: requestID, subtype: subtype)
        }
    }

    private static func decodeCanUseTool(requestID: String, _ request: [String: JSONValue],
                                         line: String) -> ClaudeFrame {
        guard let toolName = request["tool_name"]?.stringValue,
              let input = request["input"], input.objectValue != nil,
              let rawRequest = JSONText.rawMember("request", of: line[...]),
              let rawInput = JSONText.rawMember("input", of: rawRequest) else {
            return violation("can_use_tool without tool_name and an input object", line)
        }
        var questions: [Question]?
        if request["requires_user_interaction"]?.boolValue == true, let raw = input["questions"] {
            guard let parsed = parseQuestions(raw) else {
                return violation("can_use_tool input.questions is not a question list", line)
            }
            questions = parsed
        }
        let suggestions = request["permission_suggestions"]?.arrayValue ?? []
        let title = ["description", "title", "display_name"]
            .lazy.compactMap { request[$0]?.stringValue }.first { !$0.isEmpty }
        return .canUseTool(ClaudeToolRequest(
            requestID: requestID,
            toolName: toolName,
            inputJSON: String(rawInput),
            title: title,
            reason: request["decision_reason"]?.stringValue.map(withoutANSIEscapes),
            suggestionsJSON: suggestions.isEmpty ? nil : JSONText.serialize(.array(suggestions)),
            suppressAlwaysAllow: request["suppress_always_allow_rule"]?.boolValue ?? false,
            questions: questions,
            toolUseID: request["tool_use_id"]?.stringValue))
    }

    /// `nil` for anything that is not a non-empty list of well-formed questions. Claude keys a
    /// question by its text, and every question takes free text.
    static func parseQuestions(_ value: JSONValue) -> [Question]? {
        guard let items = value.arrayValue, !items.isEmpty else { return nil }
        var questions: [Question] = []
        for item in items {
            guard let text = item["question"]?.stringValue else { return nil }
            var options: [QuestionOption] = []
            for option in item["options"]?.arrayValue ?? [] {
                guard let label = option["label"]?.stringValue else { return nil }
                options.append(QuestionOption(label: label,
                                              description: option["description"]?.stringValue))
            }
            questions.append(Question(key: text,
                                      header: item["header"]?.stringValue,
                                      text: text,
                                      options: options,
                                      multiSelect: item["multiSelect"]?.boolValue ?? false,
                                      allowsFreeText: true))
        }
        return questions
    }

    /// `decision_reason` "may carry ANSI escapes" ([sdk.d.ts] `SDKControlPermissionRequest`);
    /// the reason is spoken and shown, so CSI sequences go.
    static func withoutANSIEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "",
                                  options: .regularExpression)
    }

    private static func violation(_ detail: String, _ line: String) -> ClaudeFrame {
        let preview = line.count <= previewLength ? line : String(line.prefix(previewLength)) + "…"
        return .violation("\(detail): \(preview)")
    }

    // MARK: - Encoding

    /// `{"type":"user","message":{"role":"user","content":"…"},"parent_tool_use_id":null,"session_id":""}`
    ///
    /// `session_id` is empty and `parent_tool_use_id` null exactly as the Python SDK writes
    /// them; the CLI takes the session from argv, not from this line.
    public static func encodeUserMessage(_ text: String) -> String {
        JSONText.object([
            ("type", JSONText.quoted("user")),
            ("message", JSONText.object([
                ("role", JSONText.quoted("user")),
                ("content", JSONText.quoted(text)),
            ])),
            ("parent_tool_use_id", "null"),
            ("session_id", JSONText.quoted("")),
        ])
    }

    /// Allow, carrying the tool's own input back verbatim as `updatedInput`, and with
    /// `updatedPermissions` for "don't ask again".
    public static func encodeAllow(requestID: String, updatedInputJSON: String,
                                   updatedPermissionsJSON: String? = nil) -> String {
        var pairs = [("behavior", JSONText.quoted("allow")), ("updatedInput", updatedInputJSON)]
        if let updatedPermissionsJSON { pairs.append(("updatedPermissions", updatedPermissionsJSON)) }
        return controlResponse(requestID: requestID, response: JSONText.object(pairs))
    }

    public static func encodeDeny(requestID: String, message: String) -> String {
        controlResponse(requestID: requestID, response: JSONText.object([
            ("behavior", JSONText.quoted("deny")),
            ("message", JSONText.quoted(message)),
        ]))
    }

    /// The AskUserQuestion answer K0 measured: allow, the questions verbatim, and one
    /// `answers` entry per question, keyed by its text, in question order. An exact option
    /// label and free text go in the same slot; the CLI tells them apart itself.
    public static func encodeQuestionAnswer(requestID: String, questionsJSON: String,
                                            answers: [(question: String, answer: String)]) -> String {
        controlResponse(requestID: requestID, response: JSONText.object([
            ("behavior", JSONText.quoted("allow")),
            ("updatedInput", JSONText.object([
                ("questions", questionsJSON),
                ("answers", JSONText.object(answers.map { ($0.question, JSONText.quoted($0.answer)) })),
            ])),
        ]))
    }

    public static func encodeInterrupt(requestID: String) -> String {
        JSONText.object([
            ("type", JSONText.quoted("control_request")),
            ("request_id", JSONText.quoted(requestID)),
            ("request", JSONText.object([("subtype", JSONText.quoted("interrupt"))])),
        ])
    }

    /// The MCP elicitation result that refuses without asking anyone (research §2.2).
    public static func encodeElicitationDecline(requestID: String) -> String {
        controlResponse(requestID: requestID,
                        response: JSONText.object([("action", JSONText.quoted("decline"))]))
    }

    /// The protocol's answer to a control request TapQ does not handle (research §2.2).
    public static func encodeControlError(requestID: String, message: String) -> String {
        JSONText.object([
            ("type", JSONText.quoted("control_response")),
            ("response", JSONText.object([
                ("subtype", JSONText.quoted("error")),
                ("request_id", JSONText.quoted(requestID)),
                ("error", JSONText.quoted(message)),
            ])),
        ])
    }

    private static func controlResponse(requestID: String, response: String) -> String {
        JSONText.object([
            ("type", JSONText.quoted("control_response")),
            ("response", JSONText.object([
                ("subtype", JSONText.quoted("success")),
                ("request_id", JSONText.quoted(requestID)),
                ("response", response),
            ])),
        ])
    }
}
