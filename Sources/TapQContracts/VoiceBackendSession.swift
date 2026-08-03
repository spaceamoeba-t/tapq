import Foundation

/// An illegal move against `VoiceTurnStateMachine`.
///
/// Cases are specific rather than a single `.invalidTransition` because each one names a
/// distinct bug: `.noUserTurn` is a caller that forgot to open a window, while
/// `.responseDuringUserTurn` is a caller (or a backend) trying to talk over the wearer.
/// Adapters surface these as `VoiceBackendFailure.protocolViolation`.
public enum VoiceTurnViolation: Error, LocalizedError, Equatable, Sendable {
    /// The operation needs an open session and there is none.
    case notOpen
    /// `open` on a session that is already open.
    case alreadyOpen
    /// `beginUserTurn` while a user turn is already open (double-begin).
    case turnAlreadyInProgress
    /// `endUserTurn` or `sendAudio` with no user turn open.
    case noUserTurn
    /// `requestResponse` while the wearer's turn is still open. Half-duplex is TapQ
    /// policy even against a duplex-capable backend: a window that is listening and
    /// speaking at once hears its own synthesizer.
    case responseDuringUserTurn
    /// `requestResponse` while a response is still being produced.
    case responseAlreadyInFlight
    /// `cancelResponse` or a `responseCompleted` event with nothing in flight.
    case noResponseInFlight
    /// `cancelResponse` against a backend whose `capabilities.supportsBargeIn` is false.
    /// Rejected rather than ignored so a caller can never believe barge-in worked.
    case bargeInUnsupported

    public var errorDescription: String? {
        switch self {
        case .notOpen:
            return "The voice backend session is not open."
        case .alreadyOpen:
            return "The voice backend session is already open."
        case .turnAlreadyInProgress:
            return "A user turn is already open; TapQ opens exactly one at a time."
        case .noUserTurn:
            return "No user turn is open."
        case .responseDuringUserTurn:
            return "A response cannot be requested while the user's turn is open; TapQ runs half-duplex."
        case .responseAlreadyInFlight:
            return "A response is already in flight."
        case .noResponseInFlight:
            return "No response is in flight."
        case .bargeInUnsupported:
            return "This voice backend does not support barge-in."
        }
    }
}

/// The turn protocol every `VoiceBackend` adapter runs internally, as a pure value type.
///
/// This exists so "TapQ owns turns" is enforced mechanically instead of by convention in
/// each adapter. An adapter routes every inbound call and every backend event through
/// this machine before touching its transport; a backend that tries to end a turn on its
/// own — the exact hole the design rule forbids — hits `.noUserTurn` or
/// `.noResponseInFlight` here instead of quietly resolving an approval window.
///
/// Legal cycle:
///
///     idle --open--> open --beginUserTurn--> userTurn --endUserTurn--> committed
///       ^                ^                                                 |
///       |                |                                  requestResponse|
///     close/           responseCompleted <--responding<---------------------
///     sessionFailed          (or straight from committed, for a
///     (from anywhere)         transcript-only backend)
///
/// Teardown (`close`) and failure (`sessionFailed`) are legal from every state and never
/// throw: a state machine that can refuse to shut down is a microphone leak.
///
/// Purely a legality checker — it holds no audio, no transcripts, and no timers, so it is
/// exhaustively testable without a transport.
public struct VoiceTurnStateMachine: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// No session. The state before `open` and after `close`/`sessionFailed`.
        case idle
        /// Session established, no turn in progress.
        case open
        /// The wearer's turn: `sendAudio` is accepted here and nowhere else.
        case userTurn
        /// The turn is committed; the backend may finalize transcripts.
        case committed
        /// The backend is producing a response.
        case responding
    }

    public private(set) var state: State
    public let capabilities: VoiceBackendCapabilities

    public init(capabilities: VoiceBackendCapabilities = .transcriptOnly) {
        self.capabilities = capabilities
        self.state = .idle
    }

    public var isOpen: Bool { state != .idle }
    public var isUserTurnActive: Bool { state == .userTurn }
    public var isResponding: Bool { state == .responding }

    public mutating func open() throws {
        guard state == .idle else { throw VoiceTurnViolation.alreadyOpen }
        state = .open
    }

    public mutating func beginUserTurn() throws {
        switch state {
        case .idle: throw VoiceTurnViolation.notOpen
        case .userTurn: throw VoiceTurnViolation.turnAlreadyInProgress
        case .responding: throw VoiceTurnViolation.responseAlreadyInFlight
        case .open, .committed:
            // `.committed` is a legal starting point: a transcript-only backend that
            // never requests a response goes straight from one committed turn into the
            // next without an intervening `responseCompleted`.
            state = .userTurn
        }
    }

    public mutating func sendAudio() throws {
        switch state {
        case .idle: throw VoiceTurnViolation.notOpen
        case .userTurn: break
        case .open, .committed, .responding: throw VoiceTurnViolation.noUserTurn
        }
    }

    public mutating func endUserTurn() throws {
        switch state {
        case .idle: throw VoiceTurnViolation.notOpen
        case .userTurn: state = .committed
        case .open, .committed, .responding: throw VoiceTurnViolation.noUserTurn
        }
    }

    public mutating func requestResponse() throws {
        switch state {
        case .idle: throw VoiceTurnViolation.notOpen
        case .userTurn: throw VoiceTurnViolation.responseDuringUserTurn
        case .responding: throw VoiceTurnViolation.responseAlreadyInFlight
        case .open, .committed: state = .responding
        }
    }

    public mutating func cancelResponse() throws {
        guard state != .idle else { throw VoiceTurnViolation.notOpen }
        // Capability is checked before state so a caller that wired up barge-in against a
        // backend that cannot do it learns that, rather than learning it only on the rare
        // occasions a response happens to be in flight.
        guard capabilities.supportsBargeIn else { throw VoiceTurnViolation.bargeInUnsupported }
        guard state == .responding else { throw VoiceTurnViolation.noResponseInFlight }
        state = .open
    }

    /// The backend reported `VoiceBackendEvent.responseCompleted`.
    ///
    /// Legal from `.responding` (a speaking backend finished its audio) and from
    /// `.committed` (a transcript-only backend finished recognizing). Anywhere else it
    /// means the backend completed something nobody asked for.
    public mutating func responseCompleted() throws {
        switch state {
        case .responding, .committed: state = .open
        case .idle: throw VoiceTurnViolation.notOpen
        case .open, .userTurn: throw VoiceTurnViolation.noResponseInFlight
        }
    }

    /// The backend reported `VoiceBackendEvent.sessionFailed`. Always legal, from any
    /// state: failures arrive whenever they arrive.
    public mutating func sessionFailed() {
        state = .idle
    }

    /// Teardown. Always legal and idempotent, from any state.
    public mutating func close() {
        state = .idle
    }
}
