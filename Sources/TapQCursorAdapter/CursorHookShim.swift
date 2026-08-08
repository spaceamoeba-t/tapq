import Foundation
import TapQContracts
import TapQWireProtocol

/// Decision logic for the Cursor agent-hook executable.
///
/// Cursor invokes the shim with one JSON object on stdin and reads one JSON object from
/// stdout. The shim normalizes supported events onto TapQ's agent-neutral broker protocol,
/// then emits only documented Cursor hook output. Every parse, transport, and broker
/// failure is fail-open: no stdout and exit code 0 leave Cursor's native approval or turn
/// flow in control, which is also Cursor's documented default (`failClosed` is false, so a
/// crashed, timed-out, or non-JSON hook lets the action through Cursor's own flow).
///
/// Wire format source: https://cursor.com/docs/agent/hooks — `hook_event_name`, the
/// per-event stdin fields parsed below, and the `permission` / `agent_message` response
/// fields. Cursor's own docs are the only authority used here; the shim never guesses a
/// field that page does not define.
public struct CursorHookShim {
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

    /// Cursor's `preToolUse` tool types TapQ answers. Every other type — including `Shell`,
    /// which arrives through the dedicated `beforeShellExecution` event — passes through
    /// even if this executable is invoked by a user-authored matcher.
    static let managedPreToolUseTools: Set<String> = [CursorTool.write, CursorTool.delete]

    /// Cursor reports an ordinary finished turn as `completed`; `aborted` and `error` mean
    /// the user or the client already ended it, so announcing completion would be noise.
    static let completedStopStatus = "completed"

    private static let agent = AgentIdentity.cursor
    private static let agentIdentity: JSONValue = .object([
        "id": .string(agent.id),
        "display_name": .string(agent.displayName),
    ])

    /// Exit 0 with no output is Cursor's documented pass-through behavior.
    static let passThrough = Result(stdout: nil, exitCode: 0)

    public static func handle(
        stdinData: Data,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        let diagnostics = TapQDiagnosticEmitter(category: "CursorHook", sink: diagnosticSink)
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
        case "beforeShellExecution":
            return handleBeforeShellExecution(input, diagnostics: diagnostics, send: send)
        case "preToolUse":
            return handlePreToolUse(input, diagnostics: diagnostics, send: send)
        case "stop":
            return handleStop(input, diagnostics: diagnostics, send: send)
        default:
            return passThrough
        }
    }

    // MARK: - beforeShellExecution

    /// Cursor runs this hook before every shell command, so it is a strict pre-tool gate
    /// rather than a report that Cursor was about to prompt. Sandboxed executions are the
    /// one documented exception TapQ can recognize: Cursor runs them without asking, so a
    /// hands-free approval there would add an interruption Cursor never intended.
    private static func handleBeforeShellExecution(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard hasCommonFields(input),
              let cwd = nonempty(input["cwd"]?.stringValue),
              isAbsentOrBool(input["sandbox"]),
              let command = nonempty(input["command"]?.stringValue) else {
            diagnostics.record("before_shell_execution.invalid_input", level: .warning)
            return passThrough
        }
        guard input["sandbox"]?.boolValue != true else {
            diagnostics.record("before_shell_execution.sandboxed")
            return passThrough
        }

        return decide(
            input,
            toolName: CursorTool.shell,
            toolInput: ["command": .string(command)],
            cwd: cwd,
            event: "beforeShellExecution",
            diagnostics: diagnostics,
            send: send
        )
    }

    // MARK: - preToolUse

    /// The only Cursor `preToolUse` calls TapQ manages are the mutating file tools. Cursor
    /// documents `tool_input` as an open object, so it is forwarded verbatim to the local
    /// broker and never rendered into speech beyond the resolved path.
    private static func handlePreToolUse(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard let toolName = input["tool_name"]?.stringValue,
              managedPreToolUseTools.contains(toolName) else {
            return passThrough
        }
        guard hasCommonFields(input),
              let cwd = nonempty(input["cwd"]?.stringValue),
              let toolInput = input["tool_input"]?.objectValue else {
            diagnostics.record("pre_tool_use.invalid_input", level: .warning)
            return passThrough
        }

        return decide(
            input,
            toolName: toolName,
            toolInput: toolInput,
            cwd: cwd,
            event: "preToolUse",
            diagnostics: diagnostics,
            send: send
        )
    }

    // MARK: - Approval round trip

    /// One authenticated broker round trip, then one documented Cursor permission value.
    /// A deferral, a broker error, and an unreachable broker are all indistinguishable to
    /// Cursor: the hook stays silent and Cursor applies its own permission flow.
    private static func decide(
        _ input: [String: JSONValue],
        toolName: String,
        toolInput: [String: JSONValue],
        cwd: String,
        event: String,
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        let presentation = CursorToolSummary.render(toolName: toolName, input: toolInput)
        let message: [String: JSONValue] = [
            "type": .string(WireType.approval),
            "agent": agentIdentity,
            "session_id": .string(input["conversation_id"]?.stringValue ?? ""),
            "cwd": .string(cwd),
            "tool_name": .string(toolName),
            "tool_input": .object(toolInput),
            // Cursor's hook payloads carry no permission-mode field, and these events fire
            // whether or not Cursor would have prompted, so this is a strict pre-tool gate.
            "permission_mode": .null,
            "approval_source": .string(ApprovalSource.preToolUse.rawValue),
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
                "\(event).send_failed",
                level: .warning,
                fields: ["error": "\(error)"]
            )
            return passThrough
        }

        guard let response = try? JSONDecoder().decode(
            [String: JSONValue].self,
            from: reply
        ) else {
            diagnostics.record("\(event).bad_reply", level: .warning)
            return passThrough
        }
        guard response["error"] == nil else {
            diagnostics.record(
                "\(event).broker_error",
                level: .warning,
                fields: ["error": response["error"]?.stringValue ?? "unknown"]
            )
            return passThrough
        }

        let decision = response["decision"]?.stringValue ?? "unknown"
        diagnostics.record("\(event).decision", fields: ["decision": decision])
        switch decision {
        case "allow":
            return emitPermission("allow")
        case "deny":
            let reason = nonempty(response["reason"]?.stringValue) ?? denyReason
            return emitPermission("deny", agentMessage: reason)
        default:
            return passThrough
        }
    }

    /// Exact response shape Cursor documents for its permission-bearing hooks. Only the
    /// fields TapQ has a value for are emitted; `user_message` is omitted because the
    /// wearer already heard the request and answered it.
    private static func emitPermission(
        _ permission: String,
        agentMessage: String? = nil
    ) -> Result {
        let output = PermissionOutput(permission: permission, agentMessage: agentMessage)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(output)) ?? Data("{}".utf8)
        return Result(stdout: String(decoding: encoded, as: UTF8.self), exitCode: 0)
    }

    private struct PermissionOutput: Encodable {
        let permission: String
        let agentMessage: String?

        enum CodingKeys: String, CodingKey {
            case permission
            case agentMessage = "agent_message"
        }
    }

    // MARK: - stop

    /// Cursor's `stop` payload reports only a status and a loop count; it carries no final
    /// assistant text, so this adapter announces completion and never routes a
    /// final-response question. `followup_message` is deliberately not emitted: submitting
    /// a next user message is a turn TapQ was not asked for.
    private static func handleStop(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard hasCommonFields(input),
              let status = nonempty(input["status"]?.stringValue) else {
            diagnostics.record("stop.invalid_input", level: .warning)
            return passThrough
        }
        guard status == completedStopStatus else {
            diagnostics.record("stop.not_completed", fields: ["status": status])
            return passThrough
        }

        let notification: [String: JSONValue] = [
            "type": .string(WireType.notification),
            "agent": agentIdentity,
            "session_id": .string(input["conversation_id"]?.stringValue ?? ""),
            "event": .string("stop"),
            "summary": .null,
            "protocol_version": .number(Double(WireProtocol.version)),
        ]
        _ = try? send(notification, notifyTimeout)
        return passThrough
    }

    // MARK: - Input validation

    /// Fields Cursor documents on every hook payload. `workspace_roots` is validated for
    /// shape but not consumed: TapQ takes the working directory from the per-event `cwd`.
    private static func hasCommonFields(_ input: [String: JSONValue]) -> Bool {
        nonempty(input["conversation_id"]?.stringValue) != nil
            && nonempty(input["generation_id"]?.stringValue) != nil
            && input["workspace_roots"]?.arrayValue != nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func isAbsentOrBool(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        if case .bool = value { return true }
        return false
    }
}
