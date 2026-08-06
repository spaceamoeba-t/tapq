import Foundation
import TapQContracts

/// Merges the TTS engine's activity signal with a backend audio player's activity signal
/// into a single `SpeechActivitySignaling` that `SpeechGatedVoice` can consume unchanged.
///
/// The combined signal reports `isSpeaking == true` whenever *either* source is active:
/// - The TTS engine is speaking or has utterances queued (`SpeechEngine.isSpeaking`), OR
/// - The backend audio player is playing response audio (`VoiceResponseAudioPlaying.isPlaying`).
///
/// This is the M2 self-hearing guarantee: the microphone stays closed while any audio —
/// whether from `AVSpeechSynthesizer` or from a cloud voice backend — is sounding.
///
/// ## Ownership
///
/// Takes sole ownership of both inner observer slots:
/// - `tts.onSpeakingChange` (the TTS engine's single-observer slot)
/// - `playback.onPlayingChange` (the audio player's single-observer slot)
///
/// Exposes one outer `onSpeakingChange` for `SpeechGatedVoice` to claim. The ownership
/// chain is: engine → CombinedSpeechActivity → SpeechGatedVoice, with exactly one observer
/// at each link.
@MainActor public final class CombinedSpeechActivity: SpeechActivitySignaling {
    private let tts: SpeechActivitySignaling
    private let playback: any VoiceResponseAudioPlaying

    /// Combined state: true when either source is active.
    public private(set) var isSpeaking: Bool

    /// Single observer, fired after each combined-busy↔idle transition.
    public var onSpeakingChange: (@MainActor (Bool) -> Void)?

    /// - Parameters:
    ///   - tts: The TTS engine's activity signal (`SpeechEngine`).
    ///   - playback: The backend audio player's activity signal.
    ///
    /// Both inner observer slots must be unclaimed at init time; the asserts mirror the
    /// `SpeechGatedVoice` pattern.
    public init(tts: SpeechActivitySignaling, playback: any VoiceResponseAudioPlaying) {
        assert(tts.onSpeakingChange == nil,
               "CombinedSpeechActivity takes sole ownership of tts.onSpeakingChange")
        assert(playback.onPlayingChange == nil,
               "CombinedSpeechActivity takes sole ownership of playback.onPlayingChange")

        self.tts = tts
        self.playback = playback
        self.isSpeaking = tts.isSpeaking || playback.isPlaying

        tts.onSpeakingChange = { [weak self] _ in
            self?.recompute()
        }
        playback.onPlayingChange = { [weak self] _ in
            self?.recompute()
        }
    }

    /// Recomputes the combined state from both sources and fires the outer observer if the
    /// combined value changed. Idempotent — duplicate edges from either source collapse to
    /// at most one outer transition.
    private func recompute() {
        let combined = tts.isSpeaking || playback.isPlaying
        guard combined != isSpeaking else { return }
        isSpeaking = combined
        onSpeakingChange?(combined)
    }
}
