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
///     flow. Emitting "ask" here would force a prompt on every tool call even in a mode
///     the user set to stop being asked (acceptEdits, dontAsk, bypassPermissions).
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
    /// How long the shim will hold a turn boundary open waiting for the broker's answer.
    /// Longer than the broker's own wait budget, so the answer always arrives before the
    /// socket gives up — and the installer writes a Stop hook `timeout` longer still.
    static let instructionWaitTimeout: TimeInterval = VoiceSessionBudget.shimSocketTimeout

    static let askReason = "No hands-free response; deferring to prompt"
    static let allowReason = "Approved via TapQ"
    static let denyReason = "Denied via TapQ"
    private static let agentIdentity: JSONValue = .object([
        "id": .string(AgentIdentity.claudeCode.id),
        "display_name": .string(AgentIdentity.claudeCode.displayName),
    ])

    /// Fail-open: emit nothing and exit 0 so Claude Code falls back to its own flow.
    static let passThrough = Result(stdout: nil, exitCode: 0)

    /// - Parameter voiceSessionEnabled: whether the live runtime advertises that it will
    ///   hold this session's turn boundary open. Read from discovery by the executable, and
    ///   `false` by default — which is every run without `--voice-session`, every runtime
    ///   too old to publish the field, and every runtime that is no longer alive. A Stop
    ///   event then behaves exactly as it did before voice sessions existed.
    public static func handle(
        stdinData: Data,
        steeringEnabled: () -> Bool = { false },
        voiceSessionEnabled: () -> Bool = { false },
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
        case "Stop":             return handleStop(data, diagnostics: diagnostics,
                                                   voiceSessionEnabled: voiceSessionEnabled,
                                                   send: send)
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
        voiceSessionEnabled: () -> Bool,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        switch interceptStopQuestion(data, diagnostics: diagnostics, send: send) {
        case .block(let result):
            // An answered question already carries the turn on. There is nothing to hold
            // open: the agent is about to keep working, and the next boundary it produces
            // is where a voice session picks up again.
            return result
        case .brokerUnreachable:
            // The stop.question send itself failed, so the notification would target
            // the same dead broker and cannot succeed either — sending it anyway could
            // push the hook past its 260 s ceiling (255 s socket timeout + 8 s notify
            // = 263 s > 260 s). Skip it and pass through immediately.
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
            // Sent *after* the notification, deliberately: that notification is what makes
            // the runtime announce the turn ended, and the wearer should hear "Claude Code
            // finished" before they hear "Listening."
            return waitForInstruction(
                data,
                diagnostics: diagnostics,
                voiceSessionEnabled: voiceSessionEnabled,
                send: send
            )
        }
    }

    /// The held turn boundary (RH1): ask the broker to keep this Stop open until the wearer
    /// has something to say, and block the stop with it when they do.
    ///
    /// One long-poll round and no loop. The broker answers within its own budget, and every
    /// answer that is not an instruction — timed out, released by the wearer, runtime gone,
    /// broker unreachable, a reply this shim cannot read — is a pass-through, which lets the
    /// session idle exactly as it would have. That is what keeps the failure mode of a voice
    /// session "the mode quietly ended" rather than "the terminal is stuck".
    private static func waitForInstruction(
        _ data: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        voiceSessionEnabled: () -> Bool,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard voiceSessionEnabled() else { return passThrough }
        let message: [String: JSONValue] = [
            "type": .string(WireType.instructionWait),
            "agent": agentIdentity,
            "session_id": .string(data["session_id"]?.stringValue ?? ""),
            "request_id": .string(UUID().uuidString),
            "protocol_version": .number(Double(WireProtocol.version)),
        ]
        diagnostics.record("instruction_wait.started")

        let reply: Data
        do {
            reply = try send(message, instructionWaitTimeout)
        } catch {
            diagnostics.record("instruction_wait.send_failed", level: .warning,
                               fields: ["error": "\(error)"])
            return passThrough
        }
        guard let obj = try? JSONDecoder().decode([String: JSONValue].self, from: reply),
              obj["error"] == nil,
              obj["wait"]?.stringValue == "instruction",
              let instruction = obj["instruction"]?.stringValue, !instruction.isEmpty else {
            diagnostics.record("instruction_wait.released")
            return passThrough
        }
        diagnostics.record("instruction_wait.delivered")
        // The same Stop block an answered question uses, carrying the reply the runtime
        // composed. The shim never writes the sentence itself: the text that reaches Claude
        // is the one the wearer heard read back.
        return emitStopBlock(instruction)
    }

    /// The three outcomes of `interceptStopQuestion`, distinguished so `handleStop`
    /// knows whether the broker is still reachable for the follow-up notification.
    private enum StopInterception {
        case block(Result)
        /// No block; broker is (or may be) alive — still send the stop notification.
        case pass
        /// The stop.question send itself failed. The notification goes to the same
        /// broker, so it cannot succeed either — and attempting it could push the
        /// hook past its 260 s ceiling (255 s socket timeout + 8 s notify > 260 s).
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
        // A mode that stops Claude asking at all — dontAsk, bypassPermissions — is the
        // user opting out of hands-free interruptions, so stop questions defer to the
        // screen too. acceptEdits is not that opt-out: it silences file edits, not
        // questions, so those still reach the user hands-free.
        let mode = AgentPermissionMode(data["permission_mode"]?.stringValue)
        guard mode?.skipsStopQuestions != true else { return .pass }

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

    /// The executable derives steering from discovery plus a bounded connection-only
    /// liveness probe. The shim itself sends no broker request or application data. Any
    /// doubt → silence: a missing/stale/mismatched discovery injects nothing.
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

        // Labels-preferred: a reply carrying both labels and free_text uses labels.
        let labels = obj["selected_labels"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !labels.isEmpty {
            let selection = labels.joined(separator: ", ")
            diagnostics.record("ask_user_question.selected", fields: ["selection": selection])
            let reason = "User answered via TapQ hands-free interface. Selection: '\(selection)' for question: '\(questionText)'. Please proceed with this choice without re-asking."
            return emitPreToolUse("deny", reason)
        }

        // Free-text fallback: the wearer answered in their own words.
        if let freeText = obj["free_text"]?.stringValue, !freeText.isEmpty {
            diagnostics.record("ask_user_question.free_text", fields: ["chars": "\(freeText.count)"])
            let reason = "User answered via TapQ hands-free interface. They answered in their own words: '\(freeText)' for question: '\(questionText)'. Please proceed accordingly without re-asking."
            return emitPreToolUse("deny", reason)
        }

        diagnostics.record("ask_user_question.no_selection")
        return passThrough
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
