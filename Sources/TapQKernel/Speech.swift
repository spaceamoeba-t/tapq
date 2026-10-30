import Foundation

// MARK: - Speech input

public enum SpeechInputEvent: Sendable, Equatable {
    /// `at`: monotonic capture-clock instant of the first sample the VAD called speech
    /// (session audio origin + `audio_start_ms`). nil when the service did not say. Then
    /// the gate stays closed for this item.
    case speechStarted(itemID: String, at: TimeInterval?)
    case speechStopped(itemID: String)
    /// The settled transcript of one item (`…input_audio_transcription.completed`).
    case utterance(itemID: String, text: String)
    /// `…input_audio_transcription.failed` for one item. Its text is unknown, so nothing is
    /// routed. The kernel clears the item and logs `stt.segment_failed`.
    case utteranceFailed(itemID: String, reason: String)
    /// D4: the service's `session_expired` error. A planned rollover, not a failure.
    case sessionExpired
    /// Transport drop, other error frame, mic failure → fatal.
    case failed(reason: String)
}

/// The seam is VAD-agnostic on purpose. Item ids and `at` are on TapQ's capture clock. A
/// later client-side VAD (needed for `gpt-live-transcribe`, R T3) emits the same five
/// events, with locally minted item ids, and the kernel does not change.
@MainActor
public protocol SpeechInput: AnyObject {
    var events: AsyncStream<SpeechInputEvent> { get }
    /// Handshake, then capture starts.
    func open() async throws
    /// D4: a new STT session on the same capture.
    func reopen() async throws
    func close()
}

// MARK: - Speech output

public struct SpeechID: Hashable, Sendable, Codable {
    public let raw: Int

    public init(raw: Int) {
        self.raw = raw
    }
}

public enum SpeechOutputEvent: Sendable, Equatable {
    case started(SpeechID)
    /// The last buffer was reported played back by the output (`VoiceResponseStreamEnding
    /// .playedBack`). `at` is the monotonic instant of that report. `verbatim`: the
    /// session's own output transcript (`response.output_audio_transcript.done`) contains the
    /// input text's tokens in order. A paraphrase is `false`.
    case played(SpeechID, at: TimeInterval, verbatim: Bool)
    /// Fatal.
    case failed(SpeechID, reason: String)
}

@MainActor
public protocol SpeechOutput: AnyObject {
    var events: AsyncStream<SpeechOutputEvent> { get }
    /// One at a time: the kernel never calls `speak` before the previous id is played or failed.
    func speak(_ text: String, id: SpeechID)
    /// Shutdown only; flushes and reports nothing more.
    func cancel()
}
