import Foundation

/// Plays backend response audio — the other half of the duplex pipe for backends that
/// speak (`capabilities.producesAudio == true`).
///
/// Implemented by `BackendAudioPlayback` (macOS, AVAudioEngine); consumed by
/// `VoiceBackendCommandProvider` (portable) through this protocol. The split keeps
/// AVFoundation out of every portable target.
///
/// ## Synchronous `isPlaying` invariant
///
/// `isPlaying` **must** become `true` synchronously within the first `enqueue` call,
/// before that call returns. The mic gate (`CombinedSpeechActivity` → `SpeechGatedVoice`)
/// reads `isPlaying` on every activity-change edge; if the first sample could be scheduled
/// on the audio hardware before the gate saw `isPlaying == true`, the microphone would be
/// open for the duration of that race and would hear the first few milliseconds of the
/// agent's own voice. Making the flag rise inside `enqueue` — before any audio reaches the
/// output device — closes the window to zero.
///
/// ## Lifecycle
///
/// A typical response cycle:
/// 1. Provider receives `.audio` events → `enqueue` for each chunk.
/// 2. Provider receives `.responseCompleted` → `finishStream()`.
/// 3. The player drains its buffer and transitions `isPlaying` → `false`.
///
/// Teardown / barge-in / session failure → `stopAndFlush()` at any point; the player drops
/// outstanding audio immediately and fires exactly one `isPlaying → false` edge (or none if
/// already idle).
///
/// Single-observer `onPlayingChange` follows the same ownership rule as
/// `SpeechActivitySignaling.onSpeakingChange` — `CombinedSpeechActivity` claims it at
/// composition time; a second assignment would silently break the self-hearing guard.
@MainActor public protocol VoiceResponseAudioPlaying: AnyObject {
    /// Schedules one chunk of backend audio for playback. The player may buffer, resample,
    /// or convert as needed; the only contract is FIFO ordering and the synchronous
    /// `isPlaying` invariant above.
    func enqueue(_ chunk: VoiceAudioChunk)

    /// Signals that no more chunks will arrive for this response. The player drains its
    /// buffer and then transitions `isPlaying` → `false`.
    func finishStream()

    /// Drops all queued and in-flight audio immediately. Fires at most one
    /// `isPlaying → false` edge. Idempotent.
    func stopAndFlush()

    /// True while audio is being played or is queued for playback. Becomes `true`
    /// synchronously on the first `enqueue` of a response, and `false` only after
    /// `finishStream()` + drain or `stopAndFlush()`.
    var isPlaying: Bool { get }

    /// Single observer, fired after each playing↔idle transition (never per-chunk).
    /// `CombinedSpeechActivity` claims this at composition time.
    var onPlayingChange: (@MainActor (Bool) -> Void)? { get set }
}
