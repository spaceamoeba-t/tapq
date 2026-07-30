import Foundation
import TapQContracts

/// Speak-while-listening ("barge-in"): the utterance is enqueued and the input window
/// opened in the same main-actor turn, so motion/tap input during the prompt is not
/// lost. Keeping the microphone closed while the prompt — or ANY other utterance —
/// plays is not handled here: the voice channel itself is `SpeechGatedVoice`-wrapped
/// at composition time and tracks the speech engine's shared busy signal.
@MainActor enum BargeIn {
    /// Generic over what the window resolves to: the approval path needs the channel
    /// that produced an intent (`ResolvedInput`), the selection path only needs the
    /// intent. The speak-then-open ordering this type exists for is the same either way.
    static func listen<Input>(
        speech: SpeechPresenting,
        text: String?,
        priority: SpeechPriority,
        open: () async -> Input?
    ) async -> Input? {
        if let text { speech.speak(text, priority: priority, onFinish: nil) }
        return await open()
    }
}
