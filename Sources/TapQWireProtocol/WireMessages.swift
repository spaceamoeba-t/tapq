import Foundation
import TapQContracts

/// The newline-delimited JSON agent hook shims exchange with the broker over the Unix
/// socket. One request line in, one response line out, connection closed.

public enum WireType {
    public static let approval = "approval.request"
    public static let notification = "notification.event"
    public static let selection = "selection.request"
    public static let stopQuestion = "stop.question"
    /// Wire v5: a dictated instruction queued for delivery at the session's next turn
    /// boundary. Instructions never authorize anything — they are text for the agent.
    public static let instructionSubmit = "instruction.submit"
    /// Wire v6: a shim asking the broker to hold its session's turn boundary open until an
    /// instruction exists for it. The reply carries the instruction the boundary should
    /// deliver, or nothing — in which case the Stop proceeds and the session idles.
    public static let instructionWait = "instruction.wait"
}

/// Version of the shim↔broker wire contract. Bump on any incompatible change to the
/// message shapes in this file. The installed shim binary and the running app each
/// compile in their own copy; `isCompatible` decides whether they may talk — a mismatch
/// fails open (shim passes through; broker replies error, which the shim also treats
/// as pass-through), so a stale binary degrades loudly in logs, never wrongly allows.
///
/// Renewable instruction leases (2026-08-28) did **not** move the version, and the test for
/// that is the one this comment has always applied: both halves of the change are inert to
/// a peer that does not know them. `instruction.wait` gained an optional `lease_id`, which
/// an older broker's `Codable` ignores while answering exactly as it did; and the reply
/// gained a `wait: "renew"` value, which an older shim can never provoke (it sends no
/// lease) and would read as "nothing arrived" if it somehow did. Neither direction can
/// misread the other, so there is nothing for a version gate to protect.
public enum WireProtocol {
    public static let version = 6
    /// The immediately preceding protocol remains wire-compatible for messages that do
    /// not depend on `approval_source`. This keeps the legacy macOS runtime fallback useful
    /// for strict-policy and shared events without exposing native PermissionRequest to a
    /// broker that would interpret it as legacy PreToolUse.
    public static let legacyBridgeVersion = 2
    /// Older versions this broker still accepts, newest first.
    ///
    /// Both entries earned their place the same way: each bump since v4 has only *added* a
    /// message type — v5 `instruction.submit`, v6 `instruction.wait` — leaving every
    /// request shape an older peer knows about byte-identical. An installed shim is a
    /// binary on someone's disk that they upgrade when they upgrade, so accepting the
    /// versions whose shapes are still correct is what keeps a runtime upgrade from
    /// silently disabling their hooks.
    public static let previousAcceptedVersions = [5, 4]
    /// The newest of those, for callers that want to name "the version before this one".
    public static let previousAcceptedVersion = previousAcceptedVersions[0]

    /// The first wire version that carried a given message type. Types that predate
    /// versioning report 1, so they negotiate exactly as they always have; the two
    /// instruction-channel types are gated, because an older broker would reject each of
    /// them as an unknown message rather than answer it.
    public static func minimumVersion(for messageType: String) -> Int {
        switch messageType {
        case WireType.instructionSubmit: return 5
        case WireType.instructionWait: return 6
        default: return 1
        }
    }

    /// nil = peer predates versioning; it speaks version 1 de facto.
    /// The broker accepts the current version and every `previousAcceptedVersions` entry.
    public static func isCompatible(_ other: Int?, current: Int = version) -> Bool {
        let peer = other ?? 1
        return peer == current || (current == version && previousAcceptedVersions.contains(peer))
    }

    /// Selects the version a current shim may safely put on an outbound message.
    /// Brokers themselves continue to require a compatible version via `isCompatible`.
    ///
    /// `messageType` nil (the default) means "a message type that predates the instruction
    /// channel" — every pre-existing caller negotiates exactly as before. Passing a type
    /// whose `minimumVersion` exceeds what the peer speaks yields nil, so a current shim
    /// never stamps an instruction, or a wait, with a version its broker would misread.
    public static func outboundVersion(
        for peerVersion: Int?,
        approvalSource: ApprovalSource?,
        messageType: String? = nil
    ) -> Int? {
        let peer = peerVersion ?? 1
        let floor = messageType.map(minimumVersion(for:)) ?? 1
        if peer == version { return version }
        // A current shim speaks the older broker's own version back to it — the request
        // shapes that broker knows are identical — unless the message type postdates it.
        if previousAcceptedVersions.contains(peer) {
            return floor <= peer ? peer : nil
        }
        guard floor <= legacyBridgeVersion else { return nil }
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

/// A dictated instruction for an agent session, submitted for delivery at that session's
/// next turn boundary (wire v5).
///
/// The message carries text and nothing else that could steer policy: there is no tool
/// name, no tool input, no permission mode. An instruction can never authorize an action —
/// the broker acknowledges it with `.ok` when it was queued and `.error` when it was not.
public struct InstructionSubmitMessage: Codable, Sendable, Equatable {
    public let token: String
    public let sessionID: String
    public let text: String
    public let requestID: String
    public let protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case token, text
        case sessionID = "session_id"
        case requestID = "request_id"
        case protocolVersion = "protocol_version"
    }

    public init(token: String, sessionID: String, text: String, requestID: String,
                protocolVersion: Int? = nil) {
        self.token = token
        self.sessionID = sessionID
        self.text = text
        self.requestID = requestID
        self.protocolVersion = protocolVersion
    }
}

/// A shim asking the broker to hold this session's turn boundary open (wire v6).
///
/// Sent by a Stop hook when the runtime has advertised voice-session mode and the boundary
/// has nothing to deliver yet. The broker answers when an instruction is queued for the
/// session, when the hold is let go, or — for a lease-bearing request — when this poll's
/// bound elapses and the shim should re-park.
///
/// It carries less than any other message on this wire — who is asking, and about which
/// session. There is nothing in it to influence a decision because it asks for no decision:
/// the only thing it can come back with is text the wearer already had read back to them.
public struct InstructionWaitMessage: Codable, Sendable, Equatable {
    public let token: String
    public let sessionID: String
    public let requestID: String
    public let agent: AgentIdentity?
    /// The held boundary this poll belongs to: one value per Stop hook *invocation*, stable
    /// across every re-poll that invocation makes. `requestID` still identifies the poll;
    /// this identifies the thing being polled.
    ///
    /// Present means "I will come back" — the shim is running a renewable lease, and the
    /// broker may answer this poll with `renew` and keep the boundary registered between
    /// polls. Absent means a shim that predates leases: it asks once and expects one
    /// answer, so the broker gives it the one-shot budget it was built against.
    ///
    /// Additive and optional in both directions, which is why the wire version did not
    /// move. A broker that does not know the field ignores it and answers as it always did;
    /// a shim that does not send it is answered as it always was. See `WireProtocol`.
    public let leaseID: String?
    public let protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case token, agent
        case sessionID = "session_id"
        case requestID = "request_id"
        case leaseID = "lease_id"
        case protocolVersion = "protocol_version"
    }

    public init(token: String, sessionID: String, requestID: String,
                agent: AgentIdentity? = nil,
                leaseID: String? = nil,
                protocolVersion: Int? = nil) {
        self.token = token
        self.sessionID = sessionID
        self.requestID = requestID
        self.agent = agent
        self.leaseID = leaseID
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
    case instruction(InstructionSubmitMessage)
    case instructionWait(InstructionWaitMessage)

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
        case WireType.instructionSubmit:
            self = .instruction(try InstructionSubmitMessage(from: decoder))
        case WireType.instructionWait:
            self = .instructionWait(try InstructionWaitMessage(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown message type \(type)"))
        }
    }
}

/// The broker's reply. `decision` answers an approval; `ok` acknowledges a notification or
/// a queued instruction;
/// `error` rejects a bad/unauthorized message (the shim then fail-opens to `ask`);
/// `selection` returns the indices and labels the user chose;
/// `instructionWait` answers a held turn boundary with the instruction it should deliver,
/// or with nothing at all.
public enum BrokerResponse: Sendable, Equatable {
    case decision(Decision, reason: String?)
    case ok
    case error(String)
    case selection(indices: [Int], labels: [String], freeText: String? = nil)
    case stopQuestion(reply: String?)
    /// The reply a held boundary should hand the agent, or `nil` for "nothing arrived, and
    /// nothing is going to — let the Stop proceed".
    case instructionWait(instruction: String?)
    /// This poll's bound elapsed and the boundary is *still held*: park again.
    ///
    /// Sent only in answer to a poll that carried a `lease_id`, which is the shim saying it
    /// knows how to come back. A shim that never sends one can never receive this, and a
    /// shim that does not recognize it falls into the same branch `none` falls into and
    /// lets the Stop proceed — the failure mode is "the mode ended", never "the terminal is
    /// stuck". That is what makes the renewal additive rather than a wire break.
    case instructionWaitRenew

    private enum Key: String, CodingKey {
        case decision, reason, ok, error
        case selectedIndices = "selected_indices"
        case selectedLabels = "selected_labels"
        case freeText = "free_text"
        case action, reply
        /// The wait's own discriminator, deliberately not `action`: a stop question is
        /// already encoded with an `action`, and two shapes sharing one key would decode
        /// into whichever case the reader happened to check first.
        case wait, instruction
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
        case .selection(let indices, let labels, let freeText):
            try c.encode(indices, forKey: .selectedIndices)
            try c.encode(labels, forKey: .selectedLabels)
            if let freeText { try c.encode(freeText, forKey: .freeText) }
        case .stopQuestion(let reply):
            if let reply {
                try c.encode("answer", forKey: .action)
                try c.encode(reply, forKey: .reply)
            } else {
                try c.encode("pass", forKey: .action)
            }
        case .instructionWait(let instruction):
            if let instruction {
                try c.encode("instruction", forKey: .wait)
                try c.encode(instruction, forKey: .instruction)
            } else {
                try c.encode("none", forKey: .wait)
            }
        case .instructionWaitRenew:
            try c.encode("renew", forKey: .wait)
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
            let freeText = try c.decodeIfPresent(String.self, forKey: .freeText)
            self = .selection(indices: indices, labels: labels, freeText: freeText)
        } else if let wait = try c.decodeIfPresent(String.self, forKey: .wait) {
            // An unrecognized `wait` value decodes as "nothing arrived", which is the
            // branch that lets the Stop proceed. That is the safe reading of a word this
            // build does not know, and it is what lets new values be added here without a
            // version bump.
            switch wait {
            case "instruction":
                self = .instructionWait(
                    instruction: try c.decodeIfPresent(String.self, forKey: .instruction)
                )
            case "renew":
                self = .instructionWaitRenew
            default:
                self = .instructionWait(instruction: nil)
            }
        } else if let action = try c.decodeIfPresent(String.self, forKey: .action) {
            self = .stopQuestion(reply: action == "answer" ? try c.decodeIfPresent(String.self, forKey: .reply) : nil)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognized response"))
        }
    }
}
