import Foundation
import TapQContracts
import TapQWireProtocol

/// Decision logic for the Codex lifecycle-hook executable.
///
/// Codex invokes the shim with one JSON object on stdin. The shim normalizes supported
/// events onto TapQ's agent-neutral broker protocol, then emits only documented Codex
/// hook output. Every parse, transport, and broker failure is fail-open: no stdout and
/// exit code 0 leave Codex's native approval or turn flow in control.
public struct CodexHookShim {
    public struct Result: Equatable {
        public let stdout: String?
        public let exitCode: Int32

        public init(stdout: String?, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// The broker must retain the full interaction budget before the hook process times out.
    static let approvalTimeout: TimeInterval = InteractionBudget.shimSocketTimeout
    /// Completion notifications are fire-and-forget and should never hold up a turn.
    static let notifyTimeout: TimeInterval = 8
    static let denyReason = "Denied via TapQ"
    static let maxStopQuestionCharacters = 16_384
    private static let supportedPermissionModes: Set<String> = [
        "default", "acceptEdits", "plan", "dontAsk", "bypassPermissions",
    ]

    private static let agent = AgentIdentity.codex
    private static let agentIdentity: JSONValue = .object([
        "id": .string(agent.id),
        "display_name": .string(agent.displayName),
    ])

    /// Exit 0 with no output is Codex's documented pass-through behavior.
    static let passThrough = Result(stdout: nil, exitCode: 0)

    public static func handle(
        stdinData: Data,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        let diagnostics = TapQDiagnosticEmitter(category: "CodexHook", sink: diagnosticSink)
        guard let input = try? JSONDecoder().decode(
            [String: JSONValue].self,
            from: stdinData
        ) else {
            diagnostics.record("input.invalid", level: .warning)
            return passThrough
        }

        let event = input["hook_event_name"]?.stringValue ?? "unknown"
        diagnostics.record("handle", fields: [
            "event": event,
            "tool": input["tool_name"]?.stringValue ?? "",
        ])

        switch event {
        case "PermissionRequest":
            return handlePermissionRequest(input, diagnostics: diagnostics, send: send)
        case "Stop":
            return handleStop(input, diagnostics: diagnostics, send: send)
        default:
            return passThrough
        }
    }

    // MARK: - PermissionRequest

    /// Codex emits PermissionRequest only when its own approval flow is about to prompt.
    /// TapQ decides allow/deny when available; every other result leaves that prompt intact.
    private static func handlePermissionRequest(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard let response = sendApproval(input, diagnostics: diagnostics, send: send) else {
            return passThrough
        }
        guard response["error"] == nil else {
            diagnostics.record(
                "permission_request.broker_error",
                level: .warning,
                fields: ["error": response["error"]?.stringValue ?? "unknown"]
            )
            return passThrough
        }

        let decision = response["decision"]?.stringValue ?? "unknown"
        diagnostics.record("permission_request.decision", fields: ["decision": decision])
        switch decision {
        case "allow":
            return emitPermissionRequest("allow")
        case "deny":
            let reason = nonempty(response["reason"]?.stringValue) ?? denyReason
            return emitPermissionRequest("deny", message: reason)
        default:
            return passThrough
        }
    }

    private static func sendApproval(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> [String: JSONValue]? {
        guard hasRequiredStringFields(
            ["session_id", "turn_id", "cwd", "model"],
            in: input
        ), hasSupportedPermissionMode(input),
              isNullableString(input["transcript_path"]),
              let toolName = nonempty(input["tool_name"]?.stringValue),
              let toolInput = input["tool_input"]?.objectValue else {
            diagnostics.record("permission_request.invalid_input", level: .warning)
            return nil
        }

        let presentation = CodexToolSummary.render(toolName: toolName, input: toolInput)
        let message: [String: JSONValue] = [
            "type": .string(WireType.approval),
            "agent": agentIdentity,
            "session_id": .string(input["session_id"]?.stringValue ?? ""),
            "cwd": input["cwd"] ?? .null,
            "tool_name": .string(toolName),
            "tool_input": .object(toolInput),
            "permission_mode": input["permission_mode"] ?? .null,
            "approval_source": .string(ApprovalSource.permissionRequest.rawValue),
            "request_id": .string(UUID().uuidString),
            "summary": .string(presentation.summary),
            "detail": .string(presentation.detail),
            "protocol_version": .number(Double(WireProtocol.version)),
        ]

        let reply: Data
        do {
            reply = try send(message, approvalTimeout)
        } catch {
            diagnostics.record(
                "permission_request.send_failed",
                level: .warning,
                fields: ["error": "\(error)"]
            )
            return nil
        }

        guard let response = try? JSONDecoder().decode(
            [String: JSONValue].self,
            from: reply
        ) else {
            diagnostics.record("permission_request.bad_reply", level: .warning)
            return nil
        }
        return response
    }

    /// Exact release hook shape documented for Codex PermissionRequest.
    private static func emitPermissionRequest(
        _ behavior: String,
        message: String? = nil
    ) -> Result {
        let output = PermissionRequestOutput(
            hookSpecificOutput: .init(decision: .init(behavior: behavior, message: message))
        )
        let encoded = (try? JSONEncoder().encode(output)) ?? Data("{}".utf8)
        return Result(stdout: String(decoding: encoded, as: UTF8.self), exitCode: 0)
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

    // MARK: - Stop

    private static func handleStop(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard hasRequiredStringFields(
            ["session_id", "turn_id", "cwd", "model"],
            in: input
        ), hasSupportedPermissionMode(input),
              isNullableString(input["transcript_path"]),
              input["stop_hook_active"]?.boolValue != nil,
              isNullableString(input["last_assistant_message"]) else {
            diagnostics.record("stop.invalid_input", level: .warning)
            return passThrough
        }

        switch interceptStopQuestion(input, diagnostics: diagnostics, send: send) {
        case .block(let result):
            return result
        case .brokerUnreachable:
            // A second send would target the same unavailable broker and could outlive the
            // hook timeout after the long stop-question interaction window.
            return passThrough
        case .pass:
            let notification: [String: JSONValue] = [
                "type": .string(WireType.notification),
                "agent": agentIdentity,
                "session_id": .string(input["session_id"]?.stringValue ?? ""),
                "event": .string("stop"),
                "summary": .null,
                "protocol_version": .number(Double(WireProtocol.version)),
            ]
            _ = try? send(notification, notifyTimeout)
            return passThrough
        }
    }

    private enum StopInterception {
        case block(Result)
        case pass
        case brokerUnreachable
    }

    /// Codex supplies its final text directly. `stop_hook_active` means a previous Stop
    /// hook already continued this turn, so it must not trigger another continuation loop.
    private static func interceptStopQuestion(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> StopInterception {
        guard input["stop_hook_active"]?.boolValue != true else {
            diagnostics.record("stop_question.already_active")
            return .pass
        }
        guard let text = nonempty(input["last_assistant_message"]?.stringValue),
              text.contains("?") else {
            return .pass
        }

        let message: [String: JSONValue] = [
            "type": .string(WireType.stopQuestion),
            "agent": agentIdentity,
            "session_id": .string(input["session_id"]?.stringValue ?? ""),
            "request_id": .string(input["turn_id"]?.stringValue ?? ""),
            "text": .string(String(text.suffix(maxStopQuestionCharacters))),
            "protocol_version": .number(Double(WireProtocol.version)),
        ]

        let reply: Data
        do {
            reply = try send(message, approvalTimeout)
        } catch {
            diagnostics.record(
                "stop_question.send_failed",
                level: .warning,
                fields: ["error": "\(error)"]
            )
            return .brokerUnreachable
        }

        guard let response = try? JSONDecoder().decode(
            [String: JSONValue].self,
            from: reply
        ), response["error"] == nil,
              response["action"]?.stringValue == "answer",
              let answer = nonempty(response["reply"]?.stringValue) else {
            diagnostics.record("stop_question.pass")
            return .pass
        }

        diagnostics.record("stop_question.answered")
        return .block(emitStopBlock(answer))
    }

    /// Codex treats this top-level block as a continuation prompt rather than a denial.
    private static func emitStopBlock(_ reason: String) -> Result {
        let output = StopBlockOutput(decision: "block", reason: reason)
        let encoded = (try? JSONEncoder().encode(output)) ?? Data("{}".utf8)
        return Result(stdout: String(decoding: encoded, as: UTF8.self), exitCode: 0)
    }

    private struct StopBlockOutput: Encodable {
        let decision: String
        let reason: String
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func hasRequiredStringFields(
        _ keys: [String],
        in input: [String: JSONValue]
    ) -> Bool {
        keys.allSatisfy { nonempty(input[$0]?.stringValue) != nil }
    }

    private static func hasSupportedPermissionMode(_ input: [String: JSONValue]) -> Bool {
        guard let mode = nonempty(input["permission_mode"]?.stringValue) else {
            return false
        }
        return supportedPermissionModes.contains(mode)
    }

    private static func isNullableString(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .string, .null:
            return true
        default:
            return false
        }
    }
}
