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
    /// How many times the client has *tried* to connect, successfully or not. Attempts
    /// rather than sessions, because that is what the break tests need: a dead pipe must
    /// not be re-probed, and a probe that fails again is still a probe. Invisible from
    /// `sent` — a refused open sends no frames at all.
    private(set) var connectCount = 0

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
    /// Reply to `response.cancel` with `response.done (cancelled)`. Cleared to test a
    /// cancel racing a just-completed response (the server sends an error instead), and to
    /// test the tail arriving long after the cancel rather than on its heels.
    var acknowledgesCancelWithDone = true
    /// Announce every response with `response.created` carrying an id, as the GA service
    /// does. Cleared to model a peer that names nothing, which is the only case the
    /// adapter's id-less cancel bookkeeping has to carry.
    var namesResponses = true
    /// The id of the response the peer is producing now, `nil` between responses.
    private(set) var currentResponseID: String?
    private var responseCount = 0

    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    /// Rebuilt on every connect: a reconnect after a drop is a new stream, exactly as it
    /// would be against a real socket.
    private var frames: AsyncThrowingStream<String, any Error>?
    private var uncommittedAudio = false

    // MARK: - RealtimeTransporting

    func connect() async throws {
        connectCount += 1
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
            XCTAssertEqual(session?["type"] as? String, "realtime",
                           "the GA session object needs its discriminator")
            let input = ScriptedRealtimeServer.inputAudio(of: session)
            XCTAssertTrue(input?["turn_detection"] is NSNull,
                          "server-side turn detection must be disabled on the first frame")
        }

        // Whenever detection *is* on, it must be the one shape TapQ is allowed to ask for.
        // Asserted here rather than in one test so that any frame from any path — a mode
        // flip, a tool declaration, an instruction change — is checked, which is the whole
        // point of `sendSessionUpdate` restating the field on every update.
        if type == "session.update",
           let detection = ScriptedRealtimeServer
            .inputAudio(of: object["session"] as? [String: Any])?["turn_detection"]
            as? [String: Any] {
            XCTAssertEqual(detection["type"] as? String, "semantic_vad",
                           "the only detection TapQ may hand the service is the semantic one")
            XCTAssertNotNil(detection["eagerness"] as? String,
                            "semantic detection without an eagerness is the service's "
                                + "default, not TapQ's choice")
            XCTAssertEqual(detection["create_response"] as? Bool, false,
                           "the service may end a turn; it may never author a sentence")
            XCTAssertEqual(detection["interrupt_response"] as? Bool, false,
                           "barge-in belongs to the component that knows who spoke")
        }

        switch type {
        case "input_audio_buffer.append":
            uncommittedAudio = true
        case "input_audio_buffer.commit":
            XCTAssertTrue(uncommittedAudio || allowsEmptyCommit,
                          "the buffer was committed with nothing in it")
            uncommittedAudio = false
        case "input_audio_buffer.clear":
            // The buffer really is empty afterwards, which is why a `response.create` may
            // follow one. TapQ sends this at exactly one moment — a window ending while the
            // service owns commits — and the tail it discards must not go on looking like
            // audio nobody committed.
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

        if type == "response.create", namesResponses {
            responseCount += 1
            let id = "resp_\(responseCount)"
            currentResponseID = id
            push(RealtimeFrame.responseCreated(id: id))
        }

        if type == "response.cancel", acknowledgesCancelWithDone {
            // Model the documented cancel semantics: the real OpenAI Realtime service acks
            // a response.cancel with response.done (status "cancelled"), naming the response
            // it cancelled.
            push(RealtimeFrame.responseDoneCancelled(id: currentResponseID))
            currentResponseID = nil
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

    /// The service's own VAD ends an utterance and takes the buffer.
    ///
    /// A method rather than a raw `push`, because the buffer is server state and the fake
    /// polices it: after this the input buffer really is empty, so a client `response.create`
    /// is legal (that is the whole shape of the native-turn path) and a client
    /// `input_audio_buffer.commit` would be the empty commit the real service rejects with an
    /// `error` frame. A test that pushed the frame by hand would leave the fake believing
    /// audio was still uncommitted and fail an adapter that did the right thing.
    ///
    /// Only legal while the adapter has native turn detection on — TapQ's manual-turn
    /// contract makes an unsolicited commit a session-ending violation, and the adapter's own
    /// tests assert that. Pushing the frame directly is still how a test models the illegal
    /// case.
    /// - Parameter itemID: the item the commit creates, as the live service always names
    ///   one. `nil` models the peer that names nothing — the only case that costs TapQ the
    ///   ability to delete a segment it recognized as its own voice.
    func commitFromServerVAD(itemID: String? = "item_vad") {
        uncommittedAudio = false
        guard let itemID else { return push(#"{"type":"input_audio_buffer.committed"}"#) }
        push(#"{"type":"input_audio_buffer.committed","item_id":"\#(itemID)"}"#)
    }

    /// The whole of one utterance as the service's own VAD reports it: where speech began,
    /// where it ended, and the item the commit created. A method rather than three pushes
    /// because the *order* is what the adapter's self-audio evidence is built from, and a
    /// test that pushed them by hand could get it wrong quietly.
    func reportServerVADUtterance(itemID: String? = "item_vad") {
        push(#"{"type":"input_audio_buffer.speech_started"}"#)
        push(#"{"type":"input_audio_buffer.speech_stopped"}"#)
        commitFromServerVAD(itemID: itemID)
    }

    /// Frames of one type, in order.
    func sentFrames(ofType type: String) -> [[String: Any]] {
        sent.filter { $0["type"] as? String == type }
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

    /// `session.audio.input`, where GA keeps the format, the transcription model, and turn
    /// detection. Beta had all three flat on the session object.
    static func inputAudio(of session: [String: Any]?) -> [String: Any]? {
        (session?["audio"] as? [String: Any])?["input"] as? [String: Any]
    }

    func instructions(ofResponseAt index: Int) -> String? {
        (responseObject(at: index))?["instructions"] as? String
    }

    /// The whole `response` object of the nth `response.create`, for the fields that
    /// separate an out-of-band scripted reading from a grounded answer.
    func responseObject(at index: Int) -> [String: Any]? {
        let creates = sent.filter { $0["type"] as? String == "response.create" }
        guard index < creates.count else { return nil }
        return creates[index]["response"] as? [String: Any]
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

    /// What the service says it just spoke, settled. The other direction from the two above.
    static func spokenTranscript(_ text: String) -> String {
        frame(["type": "response.output_audio_transcript.done", "transcript": text])
    }

    static func audioDelta(_ audio: Data) -> String {
        frame(["type": "response.output_audio.delta", "delta": audio.base64EncodedString()])
    }

    static func responseCreated(id: String) -> String {
        frame(["type": "response.created", "response": ["id": id, "status": "in_progress"]])
    }

    /// An unnamed completion: the peer that omits the id, and the shape most of these tests
    /// were written against.
    static let responseDone = frame(["type": "response.done",
                                     "response": ["status": "completed"]])

    static func responseDone(id: String) -> String {
        frame(["type": "response.done", "response": ["id": id, "status": "completed"]])
    }

    static func responseDoneCancelled(id: String? = nil) -> String {
        var response: [String: Any] = ["status": "cancelled"]
        if let id { response["id"] = id }
        return frame(["type": "response.done", "response": response])
    }

    /// The frames a cancelled response still owes before its own `response.done`: the peer
    /// finishes what it had already produced, and every one of them lands after the cancel.
    static func cancelledResponseTail(id: String) -> [String] {
        ["response.output_audio.done", "response.output_audio_transcript.done",
         "response.content_part.done", "conversation.item.done", "response.output_item.done"]
            .map { frame(["type": $0, "response_id": id]) }
    }

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
