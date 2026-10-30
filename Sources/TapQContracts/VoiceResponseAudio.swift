import Foundation

/// Plays TapQ's own voice: the PCM a speech session produces, one stream at a time.
///
/// Implemented by `BackendAudioPlayback` (macOS, AVAudioEngine) and consumed by
/// `RealtimeSpeechOutput` (portable) through this protocol, which keeps AVFoundation out of
/// every portable target.
///
/// One stream at a time: the owner enqueues a reading's chunks, calls `finishStream`, and
/// starts the next reading only after the report. The player's drain, not `finishStream`,
/// ends the self-audio span that gates the microphone.
@MainActor public protocol VoiceResponseAudioPlaying: AnyObject {
    /// Schedules one chunk of the current stream, in FIFO order.
    func enqueue(_ chunk: VoiceAudioChunk)

    /// No more chunks will arrive for the current stream: every chunk enqueued since the
    /// previous report or flush. `onDrained` reports how it ended, exactly once (see
    /// `VoiceResponseStreamEnding`): at once when nothing of it is outstanding, otherwise
    /// when its last buffer has been reported played back.
    ///
    /// The report is the one signal that says TapQ's voice for a reading has actually
    /// ended; the consent gate waits on it, and no estimate may stand in for it.
    func finishStream(onDrained: (@MainActor (VoiceResponseStreamEnding) -> Void)?)

    /// Drops all queued and in-flight audio now; a finished stream is reported `.flushed`.
    /// Idempotent.
    func stopAndFlush()
}

/// How one stream ended. See `VoiceResponseAudioPlaying.finishStream(onDrained:)`.
public enum VoiceResponseStreamEnding: String, Sendable, Equatable {
    /// Every buffer of the stream was reported played back by the output, or it had none.
    case playedBack
    /// The stream was dropped before it played out: `stopAndFlush()`, or a change of
    /// output route (D7). The owner speaks the item again from its start.
    case flushed
    /// The output device is unavailable: an engine that will not start, or a refused
    /// buffer. Fatal for the owner.
    case failed
}

public extension VoiceResponseAudioPlaying {
    /// `finishStream(onDrained:)` for a caller with no use for the report.
    func finishStream() {
        finishStream(onDrained: nil)
    }
}
