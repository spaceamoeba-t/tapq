import XCTest
import Foundation
@testable import TapQVoiceBackends

/// An in-process realtime peer: it records every client frame, polices the manual-turn
/// protocol from the far side, and replays scripted server events on demand.
///
/// The point of this fake is that it is *hostile*. A permissive stub would let the adapter
/// commit turns out of order, send audio before configuring the session, or ask for a
/// response over an uncommitted buffer, and every one of those bugs would surface only
/// against the live service. So the invariants are asserted here, at the moment the frame
/// is sent:
///
/// 1. The first frame on a connection is `session.update` with turn detection disabled.
///    Everything before that ack is a session running the service's own VAD.
/// 2. No frame at all before `connect()`.
/// 3. No `response.create` while audio sits in the buffer uncommitted — the manual turn
///    cycle is append → commit → create, and a response over live audio is the server-VAD
///    behavior TapQ exists to prevent.
///
/// It also never ends a turn on its own initiative. Nothing in `push` can commit a buffer;
/// the only way a turn ends is a client frame, which is the invariant the adapter's tests
/// assert against `sentTypes`.
@MainActor
final class ScriptedRealtimeServer: RealtimeTransporting {
    /// Frames the client sent, decoded, in order.
    private(set) var sent: [[String: Any]] = []
    private(set) var isConnected = false
    private(set) var closeCount = 0

    /// Set to make `connect()` throw.
    var connectFailure: RealtimeTransportFailure?
    /// Set to make the *next* `send` throw.
    var sendFailure: RealtimeTransportFailure?
    /// When set, `connect()` suspends on it, so a test can tear down mid-handshake.
    var connectGate: (@MainActor () async -> Void)?
    /// Reply to `session.update` with `session.updated`. Cleared to test handshake timeout.
    var acknowledgesSessionUpdate = true
    /// Emit `session.created` before the ack, as the live service does.
    var announcesSessionCreated = true

    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    /// Rebuilt on every connect: a reconnect after a drop is a new stream, exactly as it
    /// would be against a real socket.
    private var frames: AsyncThrowingStream<String, any Error>?
    private var uncommittedAudio = false

    // MARK: - RealtimeTransporting

    func connect() async throws {
        if let connectGate { await connectGate() }
        if let connectFailure { throw connectFailure }
        isConnected = true
        frames = AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func send(_ frame: String) async throws {
        XCTAssertTrue(isConnected, "a frame was sent before the transport connected")
        if let sendFailure {
            self.sendFailure = nil
            throw sendFailure
        }
        guard let data = frame.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return XCTFail("a client frame was not a JSON object with a type: \(frame)")
        }

        if sent.isEmpty {
            XCTAssertEqual(type, "session.update",
                           "the session must be configured before anything else is sent")
            let session = object["session"] as? [String: Any]
            let detection = session?["turn_detection"] as? [String: Any]
            XCTAssertEqual(detection?["type"] as? String, "none",
                           "server-side turn detection must be disabled on the first frame")
        }

        switch type {
        case "input_audio_buffer.append":
            uncommittedAudio = true
        case "input_audio_buffer.commit":
            XCTAssertTrue(uncommittedAudio || allowsEmptyCommit,
                          "the buffer was committed with nothing in it")
            uncommittedAudio = false
        case "response.create":
            XCTAssertFalse(uncommittedAudio,
                           "a response was requested over an uncommitted audio buffer")
        default:
            break
        }

        sent.append(object)

        if type == "session.update" {
            if announcesSessionCreated { push(#"{"type":"session.created","session":{"id":"sess_1"}}"#) }
            if acknowledgesSessionUpdate { push(#"{"type":"session.updated"}"#) }
        }
    }

    func receiveFrames() -> AsyncThrowingStream<String, any Error> {
        frames ?? AsyncThrowingStream { continuation in
            continuation.finish(throwing: RealtimeTransportFailure.closed("never connected"))
        }
    }

    func close() {
        closeCount += 1
        isConnected = false
        continuation?.finish()
        continuation = nil
        frames = nil
    }

    // MARK: - Scripting

    /// A commit with no preceding append is normally a bug; a few tests exercise the empty
    /// window deliberately.
    var allowsEmptyCommit = true

    /// Delivers a raw server frame.
    func push(_ frame: String) {
        continuation?.yield(frame)
    }

    /// Delivers a whole scripted sequence in order.
    func push(sequence: [String]) {
        for frame in sequence { push(frame) }
    }

    /// The peer drops the connection mid-stream.
    func disconnect(_ failure: RealtimeTransportFailure = .receiveFailed("socket dropped")) {
        continuation?.finish(throwing: failure)
        continuation = nil
    }

    /// The peer hangs up cleanly.
    func hangUp() {
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Assertions

    var sentTypes: [String] { sent.compactMap { $0["type"] as? String } }

    /// Base64 payloads of every `input_audio_buffer.append`, decoded.
    var appendedAudio: [Data] {
        sent.filter { $0["type"] as? String == "input_audio_buffer.append" }
            .compactMap { $0["audio"] as? String }
            .compactMap { Data(base64Encoded: $0) }
    }

    var sessionConfiguration: [String: Any]? {
        sent.first { $0["type"] as? String == "session.update" }?["session"] as? [String: Any]
    }

    func instructions(ofResponseAt index: Int) -> String? {
        let creates = sent.filter { $0["type"] as? String == "response.create" }
        guard index < creates.count else { return nil }
        return (creates[index]["response"] as? [String: Any])?["instructions"] as? String
    }

}

/// A one-shot latch, so a test can hold an async call open at a chosen suspension point
/// and act while it is parked there.
@MainActor
final class AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

/// Server frames as the service sends them, built once so the codec tests and the adapter
/// tests are arguing about the same bytes.
enum RealtimeFrame {
    static func transcriptDelta(_ text: String) -> String {
        frame(["type": "conversation.item.input_audio_transcription.delta", "delta": text])
    }

    static func transcriptCompleted(_ text: String) -> String {
        frame(["type": "conversation.item.input_audio_transcription.completed",
               "transcript": text])
    }

    static func audioDelta(_ audio: Data) -> String {
        frame(["type": "response.output_audio.delta", "delta": audio.base64EncodedString()])
    }

    static let responseDone = frame(["type": "response.done",
                                     "response": ["status": "completed"]])

    static let sessionUpdated = #"{"type":"session.updated"}"#

    static func error(message: String, code: String? = nil,
                      type: String = "invalid_request_error") -> String {
        var error: [String: Any] = ["type": type, "message": message]
        if let code { error["code"] = code }
        return frame(["type": "error", "error": error])
    }

    /// An event type this adapter does not model — the service adds them regularly.
    static let unknownEvent = frame(["type": "rate_limits.updated",
                                     "rate_limits": [["name": "requests", "remaining": 9]]])

    private static func frame(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
