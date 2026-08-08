import Foundation
import TapQContracts
import TapQWireProtocol

/// Decision logic for the OpenCode relay executable.
///
/// OpenCode has no command-hook configuration comparable to Claude Code's
/// `settings.json` or Codex's `hooks.json`. Its documented extension surface is a
/// JavaScript/TypeScript plugin loaded from the user's OpenCode config directory, whose
/// `event` hook observes the bus and whose injected SDK client can answer a pending
/// permission over the local OpenCode server. TapQ therefore installs a minimal plugin
/// (`OpenCodePluginSource`) that normalizes those bus events onto the relay envelope this
/// shim parses, runs one broker round-trip per relayed event, and prints the decision the
/// plugin then applies through OpenCode's own API.
///
/// The relay envelope is TapQ's own contract between its plugin and its executable, not an
/// OpenCode format. Keeping the OpenCode-shaped parts in the plugin means a future change
/// to a bus-event property name is a one-line plugin edit rather than a Swift release.
///
/// Sources for the OpenCode surface this adapter targets, verified against OpenCode
/// `v1.18.15`:
/// - Plugin loading, plugin input, and the `event` hook: https://opencode.ai/docs/plugins/
/// - `permission.asked` request schema (`id`, `sessionID`, `permission`, `patterns`,
///   `metadata`, `always`, optional `tool`):
///   https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/v1/permission.ts
/// - `session.idle` and its `session.status` replacement:
///   https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/session-status-event.ts
/// - Permission reply endpoints and the `once | always | reject` reply enum:
///   https://opencode.ai/docs/server/
///
/// Every parse, transport, and broker failure is fail-open: no stdout and exit code 0
/// leave OpenCode's own on-screen permission prompt in control.
public struct OpenCodeHookShim {
    public struct Result: Equatable {
        public let stdout: String?
        public let exitCode: Int32

        public init(stdout: String?, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// The broker must retain the full interaction budget before the plugin gives up.
    static let approvalTimeout: TimeInterval = InteractionBudget.shimSocketTimeout
    /// Completion notifications are fire-and-forget and must never hold up a turn.
    static let notifyTimeout: TimeInterval = 8
    static let denyReason = "Denied via TapQ"

    /// Version of the plugin↔executable relay envelope. The installed plugin writes it and
    /// this shim requires it, so a plugin left behind by an older TapQ fails open rather
    /// than being reinterpreted under new field meanings.
    public static let relayVersion = 1

    /// Relay event names. These match OpenCode's bus event `type` values so the plugin
    /// stays a pass-through rather than a translator.
    static let permissionAskedEvent = "permission.asked"
    static let sessionIdleEvent = "session.idle"

    private static let agent = AgentIdentity.openCode
    private static let agentIdentity: JSONValue = .object([
        "id": .string(agent.id),
        "display_name": .string(agent.displayName),
    ])

    /// Exit 0 with no output is the plugin's documented pass-through signal.
    public static let passThrough = Result(stdout: nil, exitCode: 0)

    public static func handle(
        stdinData: Data,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        let diagnostics = TapQDiagnosticEmitter(category: "OpenCodeHook", sink: diagnosticSink)
        guard let input = try? JSONDecoder().decode(
            [String: JSONValue].self,
            from: stdinData
        ) else {
            diagnostics.record("input.invalid", level: .warning)
            return passThrough
        }

        guard case .number(let relayVersionNumber)? = input["tapq_relay_version"],
              Int(exactly: relayVersionNumber) == relayVersion else {
            diagnostics.record("input.relay_version_mismatch", level: .warning)
            return passThrough
        }

        let event = input["hook_event_name"]?.stringValue ?? "unknown"
        diagnostics.record("handle", fields: [
            "event": event,
            "permission": input["permission"]?.stringValue ?? "",
        ])

        switch event {
        case permissionAskedEvent:
            return handlePermissionAsked(input, diagnostics: diagnostics, send: send)
        case sessionIdleEvent:
            return handleSessionIdle(input, diagnostics: diagnostics, send: send)
        default:
            return passThrough
        }
    }

    // MARK: - permission.asked

    /// OpenCode publishes `permission.asked` only when its own rules resolved to `ask`, so
    /// this is the exact set of prompts the wearer would otherwise answer on screen.
    /// Anything TapQ cannot decide leaves that prompt untouched and usable.
    private static func handlePermissionAsked(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard hasRequiredStringFields(["session_id", "permission_id"], in: input),
              isNullableString(input["directory"]),
              let permission = nonempty(input["permission"]?.stringValue),
              let metadata = metadataObject(input["metadata"]) else {
            diagnostics.record("permission_asked.invalid_input", level: .warning)
            return passThrough
        }

        let presentation = OpenCodeToolSummary.render(
            permission: permission,
            metadata: metadata
        )
        let message: [String: JSONValue] = [
            "type": .string(WireType.approval),
            "agent": agentIdentity,
            "session_id": .string(input["session_id"]?.stringValue ?? ""),
            "cwd": input["directory"] ?? .null,
            "tool_name": .string(permission),
            "tool_input": .object(metadata),
            "permission_mode": .null,
            "approval_source": .string(ApprovalSource.permissionRequest.rawValue),
            "request_id": .string(input["permission_id"]?.stringValue ?? ""),
            "summary": .string(presentation.summary),
            "detail": .string(presentation.detail),
            "protocol_version": .number(Double(WireProtocol.version)),
        ]

        let reply: Data
        do {
            reply = try send(message, approvalTimeout)
        } catch {
            diagnostics.record(
                "permission_asked.send_failed",
                level: .warning,
                fields: ["error": "\(error)"]
            )
            return passThrough
        }

        guard let response = try? JSONDecoder().decode(
            [String: JSONValue].self,
            from: reply
        ) else {
            diagnostics.record("permission_asked.bad_reply", level: .warning)
            return passThrough
        }
        guard response["error"] == nil else {
            diagnostics.record(
                "permission_asked.broker_error",
                level: .warning,
                fields: ["error": response["error"]?.stringValue ?? "unknown"]
            )
            return passThrough
        }

        let decision = response["decision"]?.stringValue ?? "unknown"
        diagnostics.record("permission_asked.decision", fields: ["decision": decision])
        switch decision {
        case "allow":
            return emitDecision("allow")
        case "deny":
            let reason = nonempty(response["reason"]?.stringValue) ?? denyReason
            return emitDecision("deny", message: reason)
        default:
            return passThrough
        }
    }

    /// The plugin translates `allow`/`deny` into the one-time OpenCode response values.
    /// TapQ never emits a remembered decision: a hands-free answer is scoped to the single
    /// prompt it was spoken for, exactly as it is for Claude Code and Codex.
    private static func emitDecision(
        _ behavior: String,
        message: String? = nil
    ) -> Result {
        let output = PermissionDecisionOutput(
            decision: .init(behavior: behavior, message: message)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(output)) ?? Data("{}".utf8)
        return Result(stdout: String(decoding: encoded, as: UTF8.self), exitCode: 0)
    }

    private struct PermissionDecisionOutput: Encodable {
        struct Decision: Encodable {
            let behavior: String
            let message: String?
        }

        let hookEventName = OpenCodeHookShim.permissionAskedEvent
        let decision: Decision
    }

    // MARK: - session.idle

    /// OpenCode's completion signal. TapQ announces it and never blocks on the result.
    ///
    /// OpenCode currently emits both the deprecated `session.idle` event and its
    /// `session.status` replacement for the same transition, so the plugin collapses them
    /// into one relayed event before this runs. There is deliberately no final-response
    /// question interception: OpenCode exposes no documented way for a plugin to continue
    /// a finished turn the way Claude Code's and Codex's `Stop` hooks can.
    private static func handleSessionIdle(
        _ input: [String: JSONValue],
        diagnostics: TapQDiagnosticEmitter,
        send: (_ message: [String: JSONValue], _ timeout: TimeInterval) throws -> Data
    ) -> Result {
        guard hasRequiredStringFields(["session_id"], in: input),
              isNullableString(input["directory"]) else {
            diagnostics.record("session_idle.invalid_input", level: .warning)
            return passThrough
        }

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

    // MARK: - Input validation

    private static func metadataObject(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value else { return [:] }
        switch value {
        case .null: return [:]
        case .object(let object): return object
        default: return nil
        }
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

    private static func isNullableString(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        switch value {
        case .string, .null:
            return true
        default:
            return false
        }
    }
}
