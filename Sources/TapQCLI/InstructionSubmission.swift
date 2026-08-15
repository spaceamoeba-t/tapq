import Foundation
import TapQPOSIXBridgeClient
import TapQWireProtocol

/// Where a running broker is, and what it will accept.
public struct BrokerConnection: Sendable, Equatable {
    public let socketPath: String
    public let token: String
    /// The wire version the runtime published, or `nil` for a record that predates
    /// versioning.
    public let protocolVersion: Int?

    public init(socketPath: String, token: String, protocolVersion: Int?) {
        self.socketPath = socketPath
        self.token = token
        self.protocolVersion = protocolVersion
    }
}

/// Why an instruction did not reach a session.
///
/// Three failures with three different remedies, kept apart because a single "it didn't
/// work" would send an operator looking in the wrong place: start the runtime, upgrade it,
/// or read what it said.
public enum InstructionSubmitError: Error, LocalizedError, Equatable {
    /// No live runtime published a discovery record this command could read.
    case brokerUnavailable
    /// A runtime is listening, but it speaks a wire version that predates the instruction
    /// channel. Sending anyway would earn an "unknown message type" and nothing else.
    case unsupportedWireVersion(Int)
    /// The socket could not be reached or answered nothing legible.
    case transport(String)
    /// The broker answered, and its answer was no. `reason` is the wire's own error code.
    case rejected(String)
    /// The agent behind this session has no turn boundary an instruction can be delivered
    /// into (RC6). Refused before the socket is opened.
    case agentCannotBeInstructed(String)

    public var errorDescription: String? {
        switch self {
        case .brokerUnavailable:
            return "no running TapQ runtime found. Start one with `tapq serve "
                + "--wearer-gate --voice-instructions`."
        case let .unsupportedWireVersion(version):
            return "the running TapQ runtime speaks wire protocol \(version), which "
                + "predates the instruction channel (\(WireProtocol.version)). Restart it "
                + "from this build."
        case let .transport(detail):
            return "could not reach the TapQ broker: \(detail)."
        case .rejected("instruction_unavailable"):
            return "the running TapQ runtime accepts no instructions. Restart it with "
                + "`--wearer-gate --voice-instructions`."
        case .rejected("instruction_empty"):
            return "the broker read the instruction as empty."
        case .rejected("unauthorized"):
            return "the broker rejected this client's token. The discovery record and the "
                + "running runtime disagree; restart the runtime."
        case let .rejected(reason):
            return "the broker refused the instruction (\(reason))."
        case let .agentCannotBeInstructed(name):
            return "instructions aren't supported for \(name). Only agents with a turn "
                + "boundary TapQ can intercept — Claude Code and Codex — can receive one."
        }
    }
}

/// Submits one `instruction.submit` message to a running broker.
///
/// Two closures rather than direct calls to `BrokerDiscovery` and `UnixSocketClient`, for
/// the same reason the CLI's motion capture and runtime service are injected: a test must
/// be able to drive the whole command — argument parsing, capability refusal, version
/// gate, response handling, exit status — without a socket, a filesystem, or a running
/// runtime. `live` is the composition the shipped binary uses.
public struct InstructionSubmitter: Sendable {
    /// Reads the runtime's discovery record, honoring an explicit `--broker-dir`.
    public typealias Connecting = @Sendable (URL?) throws -> BrokerConnection
    /// Writes one request line and reads one response line.
    public typealias Requesting = @Sendable (Data, String) throws -> Data

    private let connect: Connecting
    private let request: Requesting
    private let makeRequestID: @Sendable () -> String

    public init(
        connect: @escaping Connecting,
        request: @escaping Requesting,
        makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.connect = connect
        self.request = request
        self.makeRequestID = makeRequestID
    }

    /// Discovery + one-shot socket, exactly as every shipped hook shim reaches the broker.
    ///
    /// `readLiveDiscovery` and not `readDiscovery`: a record left behind by a runtime that
    /// was killed would otherwise turn "nothing is running" into a connection error, and
    /// the remedy for those two is not the same sentence.
    public static let live = InstructionSubmitter(
        connect: { directory in
            let discovery = BrokerDiscovery(supportDir: directory)
            guard let record = try? discovery.readLiveDiscovery() else {
                throw InstructionSubmitError.brokerUnavailable
            }
            return BrokerConnection(
                socketPath: record.socket,
                token: record.token,
                protocolVersion: record.protocolVersion
            )
        },
        request: { payload, socketPath in
            do {
                return try UnixSocketClient.request(payload, socketPath: socketPath)
            } catch {
                throw InstructionSubmitError.transport("\(error)")
            }
        }
    )

    /// Sends the instruction and returns the broker's acknowledgement.
    ///
    /// - Throws: ``InstructionSubmitError`` for every failure the operator can act on.
    public func submit(
        sessionID: String,
        text: String,
        brokerDirectory: URL?
    ) throws {
        let connection = try connect(brokerDirectory)
        // Gated on the message type, not just on compatibility: a v4 runtime is a
        // perfectly good peer for everything else on this wire and would answer an
        // instruction with a decode failure.
        guard let version = WireProtocol.outboundVersion(
            for: connection.protocolVersion,
            approvalSource: nil,
            messageType: WireType.instructionSubmit
        ) else {
            throw InstructionSubmitError.unsupportedWireVersion(connection.protocolVersion ?? 1)
        }
        let message = InstructionSubmitMessage(
            token: connection.token,
            sessionID: sessionID,
            text: text,
            requestID: makeRequestID(),
            protocolVersion: version
        )
        var payload = try JSONEncoder().encode(message)
        // The discriminator the broker dispatches on. Encoded alongside the message rather
        // than as a property of it because `InstructionSubmitMessage` is also what the
        // broker decodes *after* the switch, where a `type` field would be dead weight.
        payload = try Self.tagged(payload, type: WireType.instructionSubmit)

        let responseData = try request(payload, connection.socketPath)
        let response: BrokerResponse
        do {
            response = try JSONDecoder().decode(BrokerResponse.self, from: responseData)
        } catch {
            throw InstructionSubmitError.transport("unreadable response")
        }
        switch response {
        case .ok:
            return
        case let .error(reason):
            throw InstructionSubmitError.rejected(reason)
        default:
            throw InstructionSubmitError.transport("unexpected response")
        }
    }

    /// Adds the wire `type` discriminator to an encoded message.
    private static func tagged(_ payload: Data, type: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw InstructionSubmitError.transport("unencodable request")
        }
        object["type"] = type
        return try JSONSerialization.data(withJSONObject: object)
    }
}
