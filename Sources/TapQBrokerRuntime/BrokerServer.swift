import Foundation
import TapQContracts
import TapQWireProtocol

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
        stopQuestionDeduplicationWindow: TimeInterval = 5
    ) {
        self.transport = transport
        self.token = token
        self.legacyAgent = legacyAgent
        self.onApproval = onApproval
        self.onNotification = onNotification
        self.onSelection = onSelection
        self.onStopQuestion = onStopQuestion
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
            if approvalSource == .preToolUse, Self.isAutoMode(message.permissionMode) {
                diagnostics.record("approval.auto_pass", fields: [
                    "tool": message.toolName,
                    "source": approvalSource.rawValue,
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
        }
    }

    static func isAutoMode(_ mode: String?) -> Bool {
        mode?.lowercased().contains("auto") == true
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

    private func validate(token received: String, version: Int?) -> Bool {
        received == token && WireProtocol.isCompatible(version)
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
