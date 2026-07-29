import Foundation
import TapQContracts

/// The newline-delimited JSON agent hook shims exchange with the broker over the Unix
/// socket. One request line in, one response line out, connection closed.

public enum WireType {
    public static let approval = "approval.request"
    public static let notification = "notification.event"
    public static let selection = "selection.request"
    public static let stopQuestion = "stop.question"
}

/// Version of the shim↔broker wire contract. Bump on any incompatible change to the
/// message shapes in this file. The installed shim binary and the running app each
/// compile in their own copy; `isCompatible` decides whether they may talk — a mismatch
/// fails open (shim passes through; broker replies error, which the shim also treats
/// as pass-through), so a stale binary degrades loudly in logs, never wrongly allows.
public enum WireProtocol {
    public static let version = 3
    /// The immediately preceding protocol remains wire-compatible for messages that do
    /// not depend on `approval_source`. This keeps the legacy macOS runtime fallback useful
    /// for strict-policy and shared events without exposing native PermissionRequest to a
    /// broker that would interpret it as legacy PreToolUse.
    public static let legacyBridgeVersion = 2

    /// nil = peer predates versioning; it speaks version 1 de facto.
    public static func isCompatible(_ other: Int?, current: Int = version) -> Bool {
        (other ?? 1) == current
    }

    /// Selects the version a current shim may safely put on an outbound message.
    /// Brokers themselves continue to require an exact version via `isCompatible`.
    public static func outboundVersion(
        for peerVersion: Int?,
        approvalSource: ApprovalSource?
    ) -> Int? {
        let peer = peerVersion ?? 1
        if peer == version { return version }
        if peer == legacyBridgeVersion, approvalSource != .permissionRequest {
            return legacyBridgeVersion
        }
        return nil
    }
}

/// A blocking approval (`tool_name` + arbitrary `tool_input`).
///
/// `approvalSource` (declared in `TapQContracts`, re-exported here) stays optional so
/// legacy v2 traffic can still be decoded. A wire-v3 broker requires an explicit value
/// before applying approval policy; it must never infer `pre_tool_use` from a missing
/// policy-significant field.
public struct ApprovalRequestMessage: Codable, Sendable, Equatable {
    public let token: String
    public let sessionID: String
    public let cwd: String?
    public let toolName: String
    public let toolInput: [String: JSONValue]
    public let permissionMode: String?
    public let approvalSource: ApprovalSource?
    public let requestID: String
    /// Adapter identity and presentation remain optional message metadata.
    public let agent: AgentIdentity?
    public let summary: String?
    public let detail: String?
    public let protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case token
        case sessionID = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionMode = "permission_mode"
        case approvalSource = "approval_source"
        case requestID = "request_id"
        case agent, summary, detail
        case protocolVersion = "protocol_version"
    }

    public init(token: String, sessionID: String, cwd: String?, toolName: String,
                toolInput: [String: JSONValue], permissionMode: String?, requestID: String,
                approvalSource: ApprovalSource? = nil,
                agent: AgentIdentity? = nil, summary: String? = nil, detail: String? = nil,
                protocolVersion: Int? = nil) {
        self.token = token
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionMode = permissionMode
        self.approvalSource = approvalSource
        self.requestID = requestID
        self.agent = agent
        self.summary = summary
        self.detail = detail
        self.protocolVersion = protocolVersion
    }
}

/// A fire-and-forget agent state change (idle / permission-waiting / stop).
public struct NotificationMessage: Codable, Sendable, Equatable {
    public let token: String
    public let sessionID: String
    public let event: Event
    public let summary: String?
    public let agent: AgentIdentity?
    public let protocolVersion: Int?

    public enum Event: String, Codable, Sendable {
        case idlePrompt = "idle_prompt"
        case permissionPrompt = "permission_prompt"
        case stop
    }

    enum CodingKeys: String, CodingKey {
        case token
        case sessionID = "session_id"
        case event
        case summary
        case agent
        case protocolVersion = "protocol_version"
    }

    public init(token: String, sessionID: String, event: Event, summary: String?,
                agent: AgentIdentity? = nil,
                protocolVersion: Int? = nil) {
        self.token = token
        self.sessionID = sessionID
        self.event = event
        self.summary = summary
        self.agent = agent
        self.protocolVersion = protocolVersion
    }
}

/// A multi-choice prompt from the agent asking the user to select one or more options.
public struct SelectionRequestMessage: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public let label: String
        public let description: String
    }

    public let token: String
    public let sessionID: String
    public let requestID: String
    public let question: String
    public let options: [Option]
    public let multiSelect: Bool
    public let agent: AgentIdentity?
    public let protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case token
        case sessionID = "session_id"
        case requestID = "request_id"
        case question, options
        case multiSelect = "multi_select"
        case agent
        case protocolVersion = "protocol_version"
    }

    public init(token: String, sessionID: String, requestID: String, question: String,
                options: [Option], multiSelect: Bool, agent: AgentIdentity? = nil,
                protocolVersion: Int? = nil) {
        self.token = token
        self.sessionID = sessionID
        self.requestID = requestID
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.agent = agent
        self.protocolVersion = protocolVersion
    }
}

/// An agent's final text reply, forwarded for question detection when it may contain
/// an unanswered question (the shim pre-filters for a "?").
public struct StopQuestionMessage: Codable, Sendable, Equatable {
    public let token: String
    public let sessionID: String
    public let requestID: String
    public let text: String
    public let agent: AgentIdentity?
    public let protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case token, text, agent
        case sessionID = "session_id"
        case requestID = "request_id"
        case protocolVersion = "protocol_version"
    }

    public init(token: String, sessionID: String, requestID: String, text: String,
                agent: AgentIdentity? = nil,
                protocolVersion: Int? = nil) {
        self.token = token
        self.sessionID = sessionID
        self.requestID = requestID
        self.text = text
        self.agent = agent
        self.protocolVersion = protocolVersion
    }
}

/// A decoded request, dispatched on the wire `type` discriminator. Decoding an unknown
/// `type` throws, so the broker never acts on a message shape it doesn't recognize.
public enum BrokerRequest: Sendable {
    case approval(ApprovalRequestMessage)
    case notification(NotificationMessage)
    case selection(SelectionRequestMessage)
    case stopQuestion(StopQuestionMessage)

    private enum TypeKey: String, CodingKey { case type }

    public init(from data: Data) throws {
        let decoder = JSONDecoder()
        self = try decoder.decode(BrokerRequest.self, from: data)
    }
}

extension BrokerRequest: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case WireType.approval:
            self = .approval(try ApprovalRequestMessage(from: decoder))
        case WireType.notification:
            self = .notification(try NotificationMessage(from: decoder))
        case WireType.selection:
            self = .selection(try SelectionRequestMessage(from: decoder))
        case WireType.stopQuestion:
            self = .stopQuestion(try StopQuestionMessage(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown message type \(type)"))
        }
    }
}

/// The broker's reply. `decision` answers an approval; `ok` acknowledges a notification;
/// `error` rejects a bad/unauthorized message (the shim then fail-opens to `ask`);
/// `selection` returns the indices and labels the user chose.
public enum BrokerResponse: Sendable, Equatable {
    case decision(Decision, reason: String?)
    case ok
    case error(String)
    case selection(indices: [Int], labels: [String])
    case stopQuestion(reply: String?)

    private enum Key: String, CodingKey {
        case decision, reason, ok, error
        case selectedIndices = "selected_indices"
        case selectedLabels = "selected_labels"
        case action, reply
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data(#"{"error":"encode"}"#.utf8)
    }
}

extension BrokerResponse: Codable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .decision(let d, let reason):
            try c.encode(d.rawValue, forKey: .decision)
            if let reason { try c.encode(reason, forKey: .reason) }
        case .ok:
            try c.encode(true, forKey: .ok)
        case .error(let msg):
            try c.encode(msg, forKey: .error)
        case .selection(let indices, let labels):
            try c.encode(indices, forKey: .selectedIndices)
            try c.encode(labels, forKey: .selectedLabels)
        case .stopQuestion(let reply):
            if let reply {
                try c.encode("answer", forKey: .action)
                try c.encode(reply, forKey: .reply)
            } else {
                try c.encode("pass", forKey: .action)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let raw = try c.decodeIfPresent(String.self, forKey: .decision) {
            let reason = try c.decodeIfPresent(String.self, forKey: .reason)
            self = .decision(Decision(rawValue: raw) ?? .ask, reason: reason)
        } else if try c.decodeIfPresent(Bool.self, forKey: .ok) == true {
            self = .ok
        } else if let msg = try c.decodeIfPresent(String.self, forKey: .error) {
            self = .error(msg)
        } else if let indices = try c.decodeIfPresent([Int].self, forKey: .selectedIndices),
                  let labels = try c.decodeIfPresent([String].self, forKey: .selectedLabels) {
            self = .selection(indices: indices, labels: labels)
        } else if let action = try c.decodeIfPresent(String.self, forKey: .action) {
            self = .stopQuestion(reply: action == "answer" ? try c.decodeIfPresent(String.self, forKey: .reply) : nil)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognized response"))
        }
    }
}
