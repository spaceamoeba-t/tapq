import Foundation
import TapQContracts
import TapQWireProtocol

/// The decision logic behind the compiled `tapq-hook` shim that Claude Code invokes for
/// PreToolUse / PermissionRequest / Notification / Stop. It reads the hook's stdin JSON,
/// forwards it to the TapQ broker, and produces the hook's expected stdout — failing safe
/// in every branch.
///
/// Two PreToolUse failure modes are distinguished, matching Claude Code's own fallback:
///   - Broker unreachable (`tapq serve` stopped/crashed/never started) or an unintelligible reply:
///     pass through silently (no stdout, exit 0) so Claude Code uses its own permission
///     flow. Emitting "ask" here would force a prompt on every tool call even in
///     auto-accept mode.
///   - Broker REACHED but it returned no allow/deny (the hands-free window timed out):
///     resolve to "ask" so the normal on-screen prompt appears.
///
/// The broker round-trip is injected (`send`) so the logic is exercised without a socket;
/// the executable wires in `BrokerDiscovery` + `UnixSocketClient`.
public struct HookShim {
    public struct Result: Equatable {
        public let stdout: String?
        public let exitCode: Int32
        public init(stdout: String?, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// Derived from the shared budget so the shim can never give up before the app's
    /// interaction window (plus queue wait) has had its full `InteractionBudget.total`.
    static let approvalTimeout: TimeInterval = InteractionBudget.shimSocketTimeout
    /// Notifications only need a moment.
    static let notifyTimeout: TimeInterval = 8

    static let askReason = "No hands-free response; deferring to prompt"
    static let allowReason = "Approved via TapQ"
    static let denyReason = "Denied via TapQ"
    private static let agentIdentity: JSONValue = .object([
        "id": .string(AgentIdentity.claudeCode.id),
        "display_name": .string(AgentIdentity.claudeCode.displayName),
    ])

    /// Fail-open: emit nothing and exit 0 so Claude Code falls back to its own flow.
    static let passThrough = Result(stdout: nil, exitCode: 0)

    public static func handle(
        stdinData: Data,
        steeringEnabled: () -> Bool = { false },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        let diagnostics = TapQDiagnosticEmitter(category: "ClaudeHook", sink: diagnosticSink)
        let data = (try? JSONDecoder().decode([String: JSONValue].self, from: stdinData)) ?? [:]
        let event = data["hook_event_name"]?.stringValue ?? "unknown"
        diagnostics.record("handle", fields: [
            "event": event,
            "tool": data["tool_name"]?.stringValue ?? "",
        ])
        switch event {
        case "PreToolUse":       return handlePreToolUse(data, diagnostics: diagnostics, send: send)
        case "PermissionRequest": return handlePermissionRequest(data, diagnostics: diagnostics, send: send)
        case "Notification":     return handleNotification(data, diagnostics: diagnostics, send: send)
        case "Stop":             return handleStop(data, diagnostics: diagnostics, send: send)
        case "UserPromptSubmit": return handleUserPromptSubmit(steeringEnabled: steeringEnabled)
        default:                 return passThrough
        }
    }

    // MARK: - Events

    private static func handlePreToolUse(
        _ data: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        let tool = data["tool_name"]?.stringValue ?? ""
        if tool == "AskUserQuestion" {
            return handleAskUserQuestion(data, diagnostics: diagnostics, send: send)
        }

        guard let obj = sendApproval(
            data,
            source: .preToolUse,
            diagnosticPrefix: "pre_tool_use",
            diagnostics: diagnostics,
            send: send
        ) else {
            return passThrough
        }
        let decision = obj["decision"]?.stringValue ?? "unknown"
        diagnostics.record("pre_tool_use.decision", fields: ["decision": decision])
        switch decision {
        case "allow": return emitPreToolUse("allow", allowReason)
        case "deny":  return emitPreToolUse("deny", obj["reason"]?.stringValue ?? denyReason)
        default:      return emitPreToolUse("ask", askReason)
        }
    }

    /// `PermissionRequest` fires only when Claude is about to show its own permission
    /// dialog. TapQ may answer allow/deny on the user's behalf. Any other broker outcome
    /// emits nothing, leaving that native dialog intact.
    private static func handlePermissionRequest(
        _ data: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard let obj = sendApproval(
            data,
            source: .permissionRequest,
            diagnosticPrefix: "permission_request",
            diagnostics: diagnostics,
            send: send
        ) else {
            return passThrough
        }
        let decision = obj["decision"]?.stringValue ?? "unknown"
        diagnostics.record("permission_request.decision", fields: ["decision": decision])
        switch decision {
        case "allow":
            return emitPermissionRequest("allow")
        case "deny":
            return emitPermissionRequest("deny", message: obj["reason"]?.stringValue ?? denyReason)
        default:
            return passThrough
        }
    }

    private static func sendApproval(
        _ data: [String: JSONValue],
        source: ApprovalSource,
        diagnosticPrefix: String,
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> [String: JSONValue]? {
        let tool = data["tool_name"]?.stringValue ?? ""
        let givenID = data["request_id"]?.stringValue
        let requestID = (givenID?.isEmpty == false) ? givenID! : UUID().uuidString
        let (summary, detail) = ToolSummary.render(
            toolName: tool,
            input: data["tool_input"]?.objectValue ?? [:]
        )
        let message: [String: JSONValue] = [
            "type": .string(WireType.approval),
            "agent": agentIdentity,
            "session_id": .string(data["session_id"]?.stringValue ?? ""),
            "cwd": data["cwd"] ?? .null,
            "tool_name": .string(data["tool_name"]?.stringValue ?? ""),
            "tool_input": data["tool_input"] ?? .object([:]),
            "permission_mode": data["permission_mode"] ?? .null,
            "approval_source": .string(source.rawValue),
            "request_id": .string(requestID),
            "summary": .string(summary),
            "detail": .string(detail),
            "protocol_version": .number(Double(WireProtocol.version)),
        ]

        let reply: Data
        do {
            reply = try send(message, approvalTimeout)
        } catch {
            diagnostics.record("\(diagnosticPrefix).send_failed", level: .warning,
                               fields: ["error": "\(error)"])
            return nil
        }
        guard let obj = try? JSONDecoder().decode([String: JSONValue].self, from: reply) else {
            diagnostics.record("\(diagnosticPrefix).bad_reply", level: .warning)
            return nil
        }
        return obj
    }

    private static func handleNotification(
        _ data: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        let message: [String: JSONValue] = [
            "type": .string(WireType.notification),
            "agent": agentIdentity,
            "session_id": .string(data["session_id"]?.stringValue ?? ""),
            "event": .string(classifyNotification(data)),
            "summary": data["message"] ?? .null,
            "protocol_version": .number(Double(WireProtocol.version)),
        ]
        _ = try? send(message, notifyTimeout)
        return passThrough
    }

    private static func handleStop(
        _ data: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        switch interceptStopQuestion(data, diagnostics: diagnostics, send: send) {
        case .block(let result):
            return result
        case .brokerUnreachable:
            // The stop.question send itself failed, so the notification would target
            // the same dead broker and cannot succeed either — sending it anyway could
            // push the hook past its 120 s ceiling (115 s socket timeout + 8 s notify
            // = 123 s > 120 s). Skip it and pass through immediately.
            return passThrough
        case .pass:
            let message: [String: JSONValue] = [
                "type": .string(WireType.notification),
                "agent": agentIdentity,
                "session_id": .string(data["session_id"]?.stringValue ?? ""),
                "event": .string("stop"),
                "summary": .null,
                "protocol_version": .number(Double(WireProtocol.version)),
            ]
            _ = try? send(message, notifyTimeout)
            return passThrough
        }
    }

    /// The three outcomes of `interceptStopQuestion`, distinguished so `handleStop`
    /// knows whether the broker is still reachable for the follow-up notification.
    private enum StopInterception {
        case block(Result)
        /// No block; broker is (or may be) alive — still send the stop notification.
        case pass
        /// The stop.question send itself failed. The notification goes to the same
        /// broker, so it cannot succeed either — and attempting it could push the
        /// hook past its 120 s ceiling (115 s socket timeout + 8 s notify > 120 s).
        case brokerUnreachable
    }

    /// The prose-question capture path: read Claude's final reply from the transcript,
    /// forward it for classification, and — only if the app returns an answer — block the
    /// stop so the answer reaches Claude. Returns `.pass` in every other situation
    /// (pre-filters, or a fast pass/error/malformed reply from a live broker), which
    /// falls back to the normal stop notification + pass-through. The Stop hook input has
    /// no `last_assistant_message` field (verified 2026-07-07); the transcript is the
    /// only source of the reply text.
    private static func interceptStopQuestion(
        _ data: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> StopInterception {
        // Auto mode mirrors the AskUserQuestion decision: the user opted out of
        // hands-free interruptions, so stop questions defer to the screen too.
        let mode = data["permission_mode"]?.stringValue ?? ""
        guard !mode.lowercased().contains("auto") else { return .pass }

        guard let transcriptPath = data["transcript_path"]?.stringValue,
              let text = TranscriptReader.lastAssistantText(transcriptPath: transcriptPath),
              text.contains("?") else { return .pass }

        let message: [String: JSONValue] = [
            "type": .string(WireType.stopQuestion),
            "agent": agentIdentity,
            "session_id": .string(data["session_id"]?.stringValue ?? ""),
            "request_id": .string(UUID().uuidString),
            "text": .string(String(text.suffix(16_384))),
            "protocol_version": .number(Double(WireProtocol.version)),
        ]

        let reply: Data
        do {
            reply = try send(message, approvalTimeout)
        } catch {
            diagnostics.record("stop_question.send_failed", level: .warning,
                               fields: ["error": "\(error)"])
            return .brokerUnreachable
        }
        guard let obj = try? JSONDecoder().decode([String: JSONValue].self, from: reply),
              obj["error"] == nil,
              obj["action"]?.stringValue == "answer",
              let answer = obj["reply"]?.stringValue, !answer.isEmpty else {
            diagnostics.record("stop_question.pass")
            return .pass
        }
        diagnostics.record("stop_question.answered")
        return .block(emitStopBlock(answer))
    }

    /// Stop-hook blocking output is TOP-LEVEL `{"decision":"block","reason":…}` —
    /// unlike PreToolUse, it is NOT wrapped in hookSpecificOutput (verified against the
    /// hooks reference, 2026-07-07). `reason` is delivered to Claude as its next
    /// instruction.
    private static func emitStopBlock(_ reason: String) -> Result {
        let output = StopBlockOutput(decision: "block", reason: reason)
        let data = (try? JSONEncoder().encode(output)) ?? Data("{}".utf8)
        return Result(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)
    }

    private struct StopBlockOutput: Encodable {
        let decision: String
        let reason: String
    }

    // MARK: - UserPromptSubmit steering (no socket round-trip)

    /// Exact nudge copy from the spec — do not reword without updating the spec.
    static let steeringNudge = "When you need the user to choose between options or confirm a decision, ask via the AskUserQuestion tool rather than in plain text."

    /// Steering is decided entirely from the discovery file (is the broker live, does it
    /// speak our protocol version, is the flag on) so the prompt path adds no socket
    /// latency. Any doubt → silence: a missing/stale/mismatched discovery injects nothing.
    private static func handleUserPromptSubmit(steeringEnabled: () -> Bool) -> Result {
        guard steeringEnabled() else { return passThrough }
        let output = UserPromptSubmitOutput(hookSpecificOutput: .init(additionalContext: steeringNudge))
        let data = (try? JSONEncoder().encode(output)) ?? Data("{}".utf8)
        return Result(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)
    }

    private struct UserPromptSubmitOutput: Encodable {
        struct Inner: Encodable {
            let hookEventName = "UserPromptSubmit"
            let additionalContext: String
        }
        let hookSpecificOutput: Inner
    }

    // MARK: - AskUserQuestion interception (broker-forwarded)

    private static func handleAskUserQuestion(
        _ data: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard let toolInput = data["tool_input"],
              let questions = toolInput["questions"]?.arrayValue,
              let firstQ = questions.first?.objectValue,
              let questionText = firstQ["question"]?.stringValue,
              let options = firstQ["options"]?.arrayValue else {
            diagnostics.record("ask_user_question.parse_failed", level: .warning)
            return passThrough
        }

        // SelectionController answers exactly one single-choice question. Multi-question
        // calls (the schema allows up to 4) and multiSelect would get a partial answer
        // wrapped in a deny reason, which the model tends to re-ask — worse than just
        // showing the on-screen prompt. Pass through until genuinely supported.
        let multiSelect = firstQ["multiSelect"]?.boolValue ?? false
        guard questions.count == 1, !multiSelect else {
            diagnostics.record("ask_user_question.unsupported_shape", fields: [
                "questions": "\(questions.count)",
                "multiSelect": "\(multiSelect)",
            ])
            return passThrough
        }

        diagnostics.record("ask_user_question.received", fields: ["options": "\(options.count)"])

        let wireOptions: [JSONValue] = options.compactMap { opt -> JSONValue? in
            guard let obj = opt.objectValue,
                  let label = obj["label"]?.stringValue else { return nil }
            return .object([
                "label": .string(label),
                "description": .string(obj["description"]?.stringValue ?? "")
            ])
        }

        let message: [String: JSONValue] = [
            "type": .string(WireType.selection),
            "agent": agentIdentity,
            "session_id": .string(data["session_id"]?.stringValue ?? ""),
            "request_id": .string(data["request_id"]?.stringValue ?? UUID().uuidString),
            "question": .string(questionText),
            "options": .array(wireOptions),
            "multi_select": .bool(multiSelect),
            "protocol_version": .number(Double(WireProtocol.version)),
        ]

        let reply: Data
        do {
            reply = try send(message, approvalTimeout)
        } catch {
            diagnostics.record("ask_user_question.send_failed", level: .warning,
                               fields: ["error": "\(error)"])
            return passThrough
        }

        guard let obj = try? JSONDecoder().decode([String: JSONValue].self, from: reply) else {
            diagnostics.record("ask_user_question.bad_reply", level: .warning)
            return passThrough
        }

        if obj["error"] != nil {
            diagnostics.record("ask_user_question.broker_error", level: .warning,
                               fields: ["error": obj["error"]?.stringValue ?? ""])
            return passThrough
        }

        guard let labels = obj["selected_labels"]?.arrayValue?.compactMap(\.stringValue),
              !labels.isEmpty else {
            diagnostics.record("ask_user_question.no_selection")
            return passThrough
        }

        let selection = labels.joined(separator: ", ")
        diagnostics.record("ask_user_question.selected", fields: ["selection": selection])
        let reason = "User answered via TapQ hands-free interface. Selection: '\(selection)' for question: '\(questionText)'. Please proceed with this choice without re-asking."
        return emitPreToolUse("deny", reason)
    }

    // MARK: - Helpers

    /// Claude Code surfaces a notification as a human-readable `message`; one that mentions
    /// permission/approval is a permission prompt, otherwise it's an idle "waiting for you".
    static func classifyNotification(_ data: [String: JSONValue]) -> String {
        let message = (data["message"]?.stringValue ?? "").lowercased()
        if message.contains("permission") || message.contains("approve") || message.contains("needs your") {
            return "permission_prompt"
        }
        return "idle_prompt"
    }

    private static func emitPreToolUse(_ decision: String, _ reason: String) -> Result {
        let output = PreToolUseOutput(hookSpecificOutput: .init(
            permissionDecision: decision, permissionDecisionReason: reason))
        let data = (try? JSONEncoder().encode(output)) ?? Data("{}".utf8)
        return Result(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)
    }

    /// The exact JSON shape Claude Code expects from a PreToolUse hook. Encoding (rather
    /// than string interpolation) keeps the broker's free-form deny `reason` properly
    /// escaped.
    private struct PreToolUseOutput: Encodable {
        struct Inner: Encodable {
            let hookEventName = "PreToolUse"
            let permissionDecision: String
            let permissionDecisionReason: String
        }
        let hookSpecificOutput: Inner
    }

    /// The exact JSON shape Claude Code expects from a PermissionRequest hook. A deny
    /// may explain the decision to Claude; allow intentionally carries no extra fields.
    private static func emitPermissionRequest(_ behavior: String, message: String? = nil) -> Result {
        let output = PermissionRequestOutput(hookSpecificOutput: .init(
            decision: .init(behavior: behavior, message: message)
        ))
        let data = (try? JSONEncoder().encode(output)) ?? Data("{}".utf8)
        return Result(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)
    }

    private struct PermissionRequestOutput: Encodable {
        struct Inner: Encodable {
            struct Decision: Encodable {
                let behavior: String
                let message: String?
            }

            let hookEventName = "PermissionRequest"
            let decision: Decision
        }

        let hookSpecificOutput: Inner
    }
}
