import XCTest
import Foundation
@testable import TapQVoiceBackends

/// An in-process realtime peer: it records every client frame, polices the session shape
/// from the far side, and replays scripted server events on demand.
///
/// The point of this fake is that it is *hostile*. The invariants are asserted at the
/// moment the frame is sent:
///
/// 1. No frame at all before `connect()`.
/// 2. The first frame on a connection is `session.update`, in the shape the test declared:
///    a transcription session (`expectsTranscriptionSession`) or an output-only speech
///    session (`expectsSpeechSession`).
/// 3. A speech session never sends input audio, and every `response.create` is out of
///    band. A `response.create` while a response is active is refused the way the service
///    refuses it, with an `error` frame.
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
    /// Set to park every `send` from now on until `close()`: a socket that stopped draining.
    var stallsSends = false
    private var stalledSends: [CheckedContinuation<Void, Never>] = []
    var parkedSends: Int { stalledSends.count }
    /// Called after each client frame is recorded, with its type and the decoded object.
    var onSend: (@MainActor (String, [String: Any]) -> Void)?
    /// Reply to `session.update` with `session.updated`. Cleared to test handshake timeout.
    var acknowledgesSessionUpdate = true
    /// Emit `session.created` before the ack, as the live service does.
    var announcesSessionCreated = true
    /// Police the transcription-only session shape on the first frame.
    var expectsTranscriptionSession = false
    /// Police the output-only speech session shape: the first frame, no input audio ever,
    /// and out-of-band responses only.
    var expectsSpeechSession = false
    /// The id of the response the peer is producing now, `nil` between responses.
    private(set) var currentResponseID: String?
    private var responseCount = 0

    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    /// Rebuilt on every connect: a reconnect is a new stream, as against a real socket.
    private var frames: AsyncThrowingStream<String, any Error>?

    // MARK: - RealtimeTransporting

    func connect() async throws {
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
        if stallsSends {
            await withCheckedContinuation { stalledSends.append($0) }
            // Released by `close()`, the frame never left; by `releaseSends()`, it leaves now.
            guard isConnected else { return }
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
            if expectsTranscriptionSession { assertTranscriptionShape(session) }
            if expectsSpeechSession { assertSpeechShape(session) }
        }
        if expectsSpeechSession {
            XCTAssertNotEqual(type, "input_audio_buffer.append",
                              "an output-only session never sends input audio")
        }
        sent.append(object)

        switch type {
        case "session.update":
            if announcesSessionCreated {
                push(#"{"type":"session.created","session":{"id":"sess_1"}}"#)
            }
            if acknowledgesSessionUpdate { push(RealtimeFrame.sessionUpdated) }
        case "response.create":
            let response = object["response"] as? [String: Any]
            XCTAssertEqual(response?["conversation"] as? String, "none",
                           "a reading is out of band: it joins no conversation")
            XCTAssertNotNil(response.flatMap(Self.readText(of:)),
                            "a reading's one input item is the user message it reads")
            if currentResponseID != nil {
                push(RealtimeFrame.error(message: "Conversation already has an active response",
                                         code: "conversation_already_has_active_response"))
            } else {
                responseCount += 1
                let id = "resp_\(responseCount)"
                currentResponseID = id
                push(RealtimeFrame.responseCreated(id: id))
            }
        default:
            break
        }
        onSend?(type, object)
    }

    func receiveFrames() -> AsyncThrowingStream<String, any Error> {
        frames ?? AsyncThrowingStream { continuation in
            continuation.finish(throwing: RealtimeTransportFailure.closed("never connected"))
        }
    }

    func close() {
        closeCount += 1
        isConnected = false
        stalledSends.forEach { $0.resume() }
        stalledSends = []
        continuation?.finish()
        continuation = nil
        frames = nil
    }

    private func assertTranscriptionShape(_ session: [String: Any]?) {
        let input = Self.inputAudio(of: session)
        XCTAssertEqual(session?["type"] as? String, "transcription",
                       "a transcription session is a different kind of session, and the "
                           + "discriminator is the whole of what says so")
        XCTAssertNil(session?["model"],
                     "a transcription session has no model producing turns")
        XCTAssertNil(session?["output_modalities"], "a session with nothing to say")
        XCTAssertNil(session?["instructions"], "there is no model to instruct")
        XCTAssertNil(session?["tools"], "there is no model to call a tool")
        XCTAssertEqual((input?["turn_detection"] as? [String: Any])?["type"] as? String,
                       "server_vad", "segment boundaries are silence")
        XCTAssertNotNil((input?["transcription"] as? [String: Any])?["model"],
                        "a transcription session with no transcriber transcribes nothing")
    }

    private func assertSpeechShape(_ session: [String: Any]?) {
        XCTAssertEqual(session?["type"] as? String, "realtime")
        XCTAssertNotNil(session?["model"] as? String)
        XCTAssertEqual(session?["output_modalities"] as? [String], ["audio"])
        XCTAssertNil(session?["tools"], "a voice that reads text has nothing to call")
        XCTAssertTrue(Self.inputAudio(of: session)?["turn_detection"] is NSNull,
                      "no VAD may start a response on an output-only session")
    }

    // MARK: - Scripting

    /// Delivers a raw server frame.
    func push(_ frame: String) {
        continuation?.yield(frame)
    }

    /// The peer's VAD hears speech begin, and end. Every parameter defaults to `nil`: the
    /// peer that states nothing, which is the shape the recording tests were written against.
    func speechStarted(itemID: String? = nil, audioStartMs: Int? = nil) {
        push(RealtimeFrame.speechStarted(itemID: itemID, audioStartMs: audioStartMs))
    }

    func speechStopped(itemID: String? = nil, audioEndMs: Int? = nil) {
        push(RealtimeFrame.speechStopped(itemID: itemID, audioEndMs: audioEndMs))
    }

    /// The active response ends with `status`, as `response.done` names it.
    func finishResponse(status: String = "completed", reason: String? = nil) {
        push(RealtimeFrame.responseDone(id: currentResponseID, status: status, reason: reason))
        currentResponseID = nil
    }

    /// Frames of one type, in order.
    func sentFrames(ofType type: String) -> [[String: Any]] {
        sent.filter { $0["type"] as? String == type }
    }

    /// The socket drains again: every parked send goes out, in order, and none parks after.
    func releaseSends() {
        stallsSends = false
        let parked = stalledSends
        stalledSends = []
        parked.forEach { $0.resume() }
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
        sentFrames(ofType: "input_audio_buffer.append")
            .compactMap { $0["audio"] as? String }
            .compactMap { Data(base64Encoded: $0) }
    }

    var sessionConfiguration: [String: Any]? {
        sent.first { $0["type"] as? String == "session.update" }?["session"] as? [String: Any]
    }

    /// `session.audio.input`, where GA keeps the format, the transcription model, and turn
    /// detection.
    static func inputAudio(of session: [String: Any]?) -> [String: Any]? {
        (session?["audio"] as? [String: Any])?["input"] as? [String: Any]
    }

    /// The text a `response.create` reads: its input must be exactly one user message
    /// holding one `input_text`; anything else is nil.
    static func readText(of response: [String: Any]) -> String? {
        guard let input = response["input"] as? [[String: Any]], input.count == 1,
              input[0]["type"] as? String == "message", input[0]["role"] as? String == "user",
              let content = input[0]["content"] as? [[String: Any]], content.count == 1,
              content[0]["type"] as? String == "input_text" else { return nil }
        return content[0]["text"] as? String
    }
}

/// Server frames as the service sends them, built once so the codec tests and the session
/// tests are arguing about the same bytes.
enum RealtimeFrame {
    static func transcriptDelta(_ text: String) -> String {
        frame(["type": "conversation.item.input_audio_transcription.delta", "delta": text])
    }

    static func transcriptCompleted(_ text: String) -> String {
        frame(["type": "conversation.item.input_audio_transcription.completed",
               "transcript": text])
    }

    /// The same two frames as the live service sends them: naming the item.
    static func transcriptDelta(_ text: String, itemID: String) -> String {
        frame(["type": "conversation.item.input_audio_transcription.delta",
               "item_id": itemID, "delta": text])
    }

    static func transcriptCompleted(_ text: String, itemID: String) -> String {
        frame(["type": "conversation.item.input_audio_transcription.completed",
               "item_id": itemID, "transcript": text])
    }

    static func transcriptFailed(itemID: String, code: String) -> String {
        frame(["type": "conversation.item.input_audio_transcription.failed",
               "item_id": itemID, "content_index": 0,
               "error": ["type": "transcription_error", "code": code, "message": "failed"]])
    }

    /// The peer taking the input buffer and naming the item it created.
    static func inputAudioCommitted(itemID: String? = nil) -> String {
        var object: [String: Any] = ["type": "input_audio_buffer.committed"]
        if let itemID { object["item_id"] = itemID }
        return frame(object)
    }

    /// What the service says it just spoke, settled.
    static func spokenTranscript(_ text: String) -> String {
        frame(["type": "response.output_audio_transcript.done", "transcript": text])
    }

    static func audioDelta(_ audio: Data) -> String {
        frame(["type": "response.output_audio.delta", "delta": audio.base64EncodedString()])
    }

    /// The VAD's two frames. A `nil` field is omitted, as a peer that states nothing omits it.
    static func speechStarted(itemID: String? = nil, audioStartMs: Int? = nil) -> String {
        var object: [String: Any] = ["type": "input_audio_buffer.speech_started"]
        if let itemID { object["item_id"] = itemID }
        if let audioStartMs { object["audio_start_ms"] = audioStartMs }
        return frame(object)
    }

    static func speechStopped(itemID: String? = nil, audioEndMs: Int? = nil) -> String {
        var object: [String: Any] = ["type": "input_audio_buffer.speech_stopped"]
        if let itemID { object["item_id"] = itemID }
        if let audioEndMs { object["audio_end_ms"] = audioEndMs }
        return frame(object)
    }

    static func responseCreated(id: String) -> String {
        frame(["type": "response.created", "response": ["id": id, "status": "in_progress"]])
    }

    /// `response.done`, with `status_details` the way the service fills it: an error for
    /// `failed`, a reason for `incomplete`.
    static func responseDone(id: String?, status: String, reason: String? = nil) -> String {
        var response: [String: Any] = ["status": status]
        if let id { response["id"] = id }
        if let reason {
            response["status_details"] = status == "failed"
                ? ["type": status, "error": ["type": "server_error", "code": reason]]
                : ["type": status, "reason": reason]
        }
        return frame(["type": "response.done", "response": response])
    }

    static let sessionUpdated = #"{"type":"session.updated"}"#

    static func error(message: String, code: String? = nil,
                      type: String = "invalid_request_error") -> String {
        var error: [String: Any] = ["type": type, "message": message]
        if let code { error["code"] = code }
        return frame(["type": "error", "error": error])
    }

    /// An event type this codec does not model — the service adds them regularly.
    static let unknownEvent = frame(["type": "rate_limits.updated",
                                     "rate_limits": [["name": "requests", "remaining": 9]]])

    private static func frame(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
