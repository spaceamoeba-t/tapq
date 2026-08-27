import Foundation
import TapQContracts
import TapQWireProtocol

/// A dictated instruction arriving over the wire, handed to the host for queuing.
///
/// Text and identity only: the instruction channel structurally cannot carry tool input,
/// working directories, or permission state, so nothing here can influence authorization.
public struct BrokerInstruction: Sendable, Equatable {
    /// The agent session the instruction is addressed to.
    public let sessionID: String
    /// The submitter's idempotency handle, echoed into diagnostics.
    public let requestID: String
    /// The instruction text, already trimmed and known non-empty.
    public let text: String

    public init(sessionID: String, requestID: String, text: String) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.text = text
    }
}

/// A turn boundary a shim is asking the broker to hold open.
///
/// Identity only, like ``BrokerInstruction`` and for the same reason: a request that can
/// carry nothing but "who is asking, about which session" cannot influence what comes back,
/// and what comes back is text the wearer already confirmed out loud.
public struct BrokerInstructionWait: Sendable, Equatable {
    /// The agent session whose boundary is being held.
    public let sessionID: String
    /// The waiter's idempotency handle, echoed into diagnostics.
    public let requestID: String
    /// The agent behind the session, when the shim named one.
    public let agent: AgentIdentity

    public init(sessionID: String, requestID: String, agent: AgentIdentity) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.agent = agent
    }
}

/// Authenticated, agent-neutral dispatcher for TapQ's local broker protocol.
///
/// Adapter-specific parsing and presentation arrive already normalized on the wire. The
/// broker validates the local token and protocol version, converts messages to shared
/// contracts, and delegates interaction policy to its host.
@MainActor public final class BrokerServer {
    private let transport: any BrokerTransport
    private let token: String
    private let legacyAgent: AgentIdentity
    private let onApproval: @MainActor (ApprovalRequest) async -> Decision
    private let onNotification: @MainActor (AgentNotification) -> Void
    private let onSelection: @MainActor (SelectionRequest) async -> SelectionResult
    private let onStopQuestion: @MainActor (StopQuestion) async -> String?
    private let onInstruction: @MainActor (BrokerInstruction) -> Bool
    private let onInstructionWait: @MainActor (BrokerInstructionWait) async -> String?
    private let stopQuestionDeduplicationWindow: TimeInterval
    private let diagnostics: TapQDiagnosticEmitter
    private var inFlightStopQuestions: [StopQuestionKey: Task<String?, Never>] = [:]
    private var recentStopQuestions: [StopQuestionKey: CompletedStopQuestion] = [:]

    public init(
        transport: any BrokerTransport,
        token: String,
        legacyAgent: AgentIdentity = .unknown,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        onApproval: @escaping @MainActor (ApprovalRequest) async -> Decision,
        onNotification: @escaping @MainActor (AgentNotification) -> Void,
        onSelection: @escaping @MainActor (SelectionRequest) async -> SelectionResult = { _ in .noSelection },
        onStopQuestion: @escaping @MainActor (StopQuestion) async -> String? = { _ in nil },
        onInstruction: @escaping @MainActor (BrokerInstruction) -> Bool = { _ in false },
        onInstructionWait: @escaping @MainActor (BrokerInstructionWait) async -> String? = {
            _ in nil
        },
        stopQuestionDeduplicationWindow: TimeInterval = 5
    ) {
        self.transport = transport
        self.token = token
        self.legacyAgent = legacyAgent
        self.onApproval = onApproval
        self.onNotification = onNotification
        self.onSelection = onSelection
        self.onStopQuestion = onStopQuestion
        // Default: no instruction queue is wired, so the channel is closed and every
        // submission is answered with an honest error rather than a silent success.
        self.onInstruction = onInstruction
        // Default: no voice session is running, so a boundary is answered the instant it
        // asks and the Stop proceeds — which is what every run without `--voice-session`
        // does, including one whose shim is newer than its runtime.
        self.onInstructionWait = onInstructionWait
        self.stopQuestionDeduplicationWindow = max(0, stopQuestionDeduplicationWindow)
        self.diagnostics = TapQDiagnosticEmitter(category: "Broker", sink: diagnosticSink)
    }

    public func start() throws {
        try transport.start { [weak self] data in
            guard let self else { return BrokerResponse.error("gone").encoded() }
            return await self.handle(data)
        }
        diagnostics.record("started")
    }

    public func stop() {
        transport.stop()
        diagnostics.record("stopped")
    }

    public func handle(_ data: Data) async -> Data {
        let request: BrokerRequest
        do {
            request = try BrokerRequest(from: data)
        } catch {
            diagnostics.record("request.rejected", level: .warning, fields: ["reason": "bad_request"])
            return BrokerResponse.error("bad request").encoded()
        }

        switch request {
        case .approval(let message):
            guard validate(token: message.token, version: message.protocolVersion) else {
                return rejection(token: message.token, version: message.protocolVersion)
            }
            guard let approvalSource = message.approvalSource else {
                diagnostics.record("request.rejected", level: .warning, fields: [
                    "reason": "approval_source",
                ])
                return BrokerResponse.error("approval_source").encoded()
            }
            if approvalSource == .preToolUse,
               Self.isAutoMode(message.permissionMode, toolName: message.toolName) {
                diagnostics.record("approval.auto_pass", fields: [
                    "tool": message.toolName,
                    "source": approvalSource.rawValue,
                    "mode": message.permissionMode ?? "",
                ])
                return BrokerResponse.decision(.allow, reason: nil).encoded()
            }
            let agent = message.agent ?? legacyAgent
            // The context fields ride the in-process contract only: a risk reasoner may
            // read them, but they stay out of the diagnostics below, which record just
            // the agent, tool name, request id, and hook source.
            let request = ApprovalRequest(
                id: message.requestID,
                sessionID: message.sessionID,
                agent: agent,
                toolName: message.toolName,
                summary: message.summary ?? Self.fallbackSummary(toolName: message.toolName),
                detail: message.detail ?? message.summary ?? message.toolName,
                toolInput: message.toolInput,
                cwd: message.cwd,
                permissionMode: message.permissionMode,
                approvalSource: approvalSource
            )
            diagnostics.record("approval.received", fields: [
                "agent": agent.id,
                "tool": message.toolName,
                "id": message.requestID,
                "source": approvalSource.rawValue,
            ])
            switch await onApproval(request) {
            case .allow:
                return BrokerResponse.decision(.allow, reason: nil).encoded()
            case .deny:
                return BrokerResponse.decision(.deny, reason: "Denied via TapQ").encoded()
            case .ask:
                return BrokerResponse.decision(.ask, reason: nil).encoded()
            }

        case .notification(let message):
            guard validate(token: message.token, version: message.protocolVersion) else {
                return rejection(token: message.token, version: message.protocolVersion)
            }
            let kind: AgentNotification.Kind
            switch message.event {
            case .idlePrompt: kind = .waitingForInput
            case .permissionPrompt: kind = .permissionWaiting
            case .stop: kind = .finished
            }
            let agent = message.agent ?? legacyAgent
            onNotification(.init(
                sessionID: message.sessionID,
                agent: agent,
                kind: kind,
                summary: message.summary
            ))
            diagnostics.record("notification.received", fields: [
                "agent": agent.id, "event": message.event.rawValue,
            ])
            return BrokerResponse.ok.encoded()

        case .selection(let message):
            guard validate(token: message.token, version: message.protocolVersion) else {
                return rejection(token: message.token, version: message.protocolVersion)
            }
            let agent = message.agent ?? legacyAgent
            let request = SelectionRequest(
                id: message.requestID,
                sessionID: message.sessionID,
                agent: agent,
                question: message.question,
                options: message.options.map {
                    SelectionOption(label: $0.label, description: $0.description)
                },
                multiSelect: message.multiSelect
            )
            let result = await onSelection(request)
            if result.timedOut { return BrokerResponse.error("timeout").encoded() }
            return BrokerResponse.selection(
                indices: result.choices.map(\.index),
                labels: result.choices.map(\.label),
                freeText: result.freeText
            ).encoded()

        case .stopQuestion(let message):
            guard validate(token: message.token, version: message.protocolVersion) else {
                return rejection(token: message.token, version: message.protocolVersion)
            }
            let agent = message.agent ?? legacyAgent
            diagnostics.record("stop_question.received", fields: [
                "agent": agent.id,
                "chars": "\(message.text.count)",
            ])
            let question = StopQuestion(
                sessionID: message.sessionID,
                agent: agent,
                text: message.text
            )
            let reply = await resolveStopQuestion(question)
            diagnostics.record(
                reply == nil ? "stop_question.passed" : "stop_question.answered",
                fields: ["agent": agent.id]
            )
            return BrokerResponse.stopQuestion(reply: reply).encoded()

        case .instruction(let message):
            // Instructions are wire-v5 only: a peer stamped v4 cannot have meant this
            // message, so the version gate is stricter here than for every other arm.
            guard validate(
                token: message.token,
                version: message.protocolVersion,
                messageType: WireType.instructionSubmit
            ) else {
                return rejection(token: message.token, version: message.protocolVersion)
            }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                diagnostics.record("request.rejected", level: .warning, fields: [
                    "reason": "instruction_empty",
                ])
                return BrokerResponse.error("instruction_empty").encoded()
            }
            // Only the length is recorded: dictated text is the wearer's speech and stays
            // out of diagnostics, exactly as stop-question text does.
            diagnostics.record("instruction.received", fields: [
                "id": message.requestID,
                "chars": "\(text.count)",
            ])
            guard onInstruction(.init(
                sessionID: message.sessionID,
                requestID: message.requestID,
                text: text
            )) else {
                diagnostics.record("instruction.rejected", level: .warning, fields: [
                    "id": message.requestID,
                ])
                return BrokerResponse.error("instruction_unavailable").encoded()
            }
            diagnostics.record("instruction.queued", fields: ["id": message.requestID])
            return BrokerResponse.ok.encoded()

        case .instructionWait(let message):
            // Wire-v6 only, on the same reasoning as `instruction.submit`: a v5 peer cannot
            // have meant this message, so the version gate is stricter here than the
            // compatibility check alone would be.
            guard validate(
                token: message.token,
                version: message.protocolVersion,
                messageType: WireType.instructionWait
            ) else {
                return rejection(token: message.token, version: message.protocolVersion)
            }
            let agent = message.agent ?? legacyAgent
            diagnostics.record("instruction_wait.received", fields: [
                "agent": agent.id,
                "id": message.requestID,
            ])
            // This is the one handler that is *expected* to take minutes. The transport
            // hands each connection to its own queue and this actor is free across every
            // suspension inside the host's wait, so a held boundary blocks neither the
            // accept loop nor another session's approval.
            let instruction = await onInstructionWait(.init(
                sessionID: message.sessionID,
                requestID: message.requestID,
                agent: agent
            ))
            // Only whether one arrived: the reply carries the wearer's own sentence, which
            // belongs in the agent's session and not in an operational log line.
            diagnostics.record(
                instruction == nil ? "instruction_wait.released" : "instruction_wait.delivered",
                fields: ["id": message.requestID]
            )
            return BrokerResponse.instructionWait(instruction: instruction).encoded()
        }
    }

    /// Strict policy routes every matched tool call through TapQ, so the broker is where
    /// a mode the agent would never have prompted for gets its silent allow. The mode
    /// alone is not enough: `acceptEdits` skips the prompt for file edits only, and Bash
    /// under it still deserves a hands-free confirmation.
    static func isAutoMode(_ mode: String?, toolName: String) -> Bool {
        AgentPermissionMode(mode)?.autoAllows(toolName: toolName) == true
    }

    private func resolveStopQuestion(_ question: StopQuestion) async -> String? {
        let key = StopQuestionKey(
            agentID: question.agent.id,
            sessionID: question.sessionID,
            text: question.text
        )
        let now = Date()
        recentStopQuestions = recentStopQuestions.filter { $0.value.expiresAt > now }

        if let completed = recentStopQuestions[key] {
            diagnostics.record("stop_question.duplicate_cached", fields: [
                "agent": question.agent.id,
            ])
            return completed.reply
        }
        if let task = inFlightStopQuestions[key] {
            diagnostics.record("stop_question.duplicate_inflight", fields: [
                "agent": question.agent.id,
            ])
            return await task.value
        }

        let handler = onStopQuestion
        let task = Task { @MainActor in
            await handler(question)
        }
        inFlightStopQuestions[key] = task
        let reply = await task.value
        inFlightStopQuestions.removeValue(forKey: key)
        recentStopQuestions[key] = CompletedStopQuestion(
            reply: reply,
            expiresAt: Date().addingTimeInterval(stopQuestionDeduplicationWindow)
        )
        return reply
    }

    /// `messageType` nil (the default) accepts any version the wire calls compatible.
    /// Passing a type additionally requires the stamped version to be one that actually
    /// carried it, so a message type cannot arrive under a version that predates it.
    private func validate(token received: String, version: Int?, messageType: String? = nil) -> Bool {
        guard received == token, WireProtocol.isCompatible(version) else { return false }
        guard let messageType else { return true }
        return (version ?? 1) >= WireProtocol.minimumVersion(for: messageType)
    }

    private func rejection(token received: String, version: Int?) -> Data {
        if received != token {
            diagnostics.record("request.rejected", level: .warning, fields: ["reason": "unauthorized"])
            return BrokerResponse.error("unauthorized").encoded()
        }
        diagnostics.record("request.rejected", level: .warning, fields: [
            "reason": "protocol_version",
            "received": version.map(String.init) ?? "nil",
            "expected": "\(WireProtocol.version)",
        ])
        return BrokerResponse.error("protocol_version").encoded()
    }

    private static func fallbackSummary(toolName: String) -> String {
        toolName.isEmpty ? "perform an action" : "use \(toolName)"
    }

    private struct StopQuestionKey: Hashable {
        let agentID: String
        let sessionID: String
        let text: String
    }

    private struct CompletedStopQuestion {
        let reply: String?
        let expiresAt: Date
    }
}
