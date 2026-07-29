import Foundation

/// Chooses which synthesizer voice TapQ speaks with.
///
/// Left unset, AVFoundation resolves the voice from the *system language* and never from
/// the text, so a Chinese-language Mac reads TapQ's English prompts with a Chinese voice
/// and the readout is barely intelligible. The default pins synthesis to en-US, mirroring
/// `VoiceListener.grammarLocale`: TapQ's own spoken scaffolding ("Approve?", "Volume, then
/// nod twice or double-tap.") is hardcoded English, and the command grammar only
/// understands English.
///
/// This selects a VOICE, not a translation. Agent-supplied summaries and option labels
/// pass through verbatim, so a non-English selection changes how TapQ's English
/// scaffolding is pronounced without localizing it. Localizing the spoken copy — and
/// lifting the recognizer's English pin with it — is separate work.
public enum SpeechVoiceSelection {
    /// Matches `VoiceListener.grammarLocale`; the two must move together.
    public static let defaultSelection = "en-US"
    public static let environmentKey = "TAPQ_SPEECH_VOICE"

    /// `--speech-voice` wins over `TAPQ_SPEECH_VOICE`, which wins over the en-US pin.
    /// The environment variable matters for the packaged runtime app, which is launched
    /// through `open` and cannot take CLI flags.
    public static func resolve(flag: String?, environment: [String: String]) -> String {
        if let flag = normalized(flag) { return flag }
        if let value = normalized(environment[environmentKey]) { return value }
        return defaultSelection
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
