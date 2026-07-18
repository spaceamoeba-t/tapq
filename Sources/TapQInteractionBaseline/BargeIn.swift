import Foundation
import TapQContracts

/// Speak-while-listening ("barge-in"): the utterance is enqueued and the input window
/// opened in the same main-actor turn, so motion/tap input during the prompt is not
/// lost. Keeping the microphone closed while the prompt — or ANY other utterance —
/// plays is not handled here: the voice channel itself is `SpeechGatedVoice`-wrapped
/// at composition time and tracks the speech engine's shared busy signal.
@MainActor enum BargeIn {
    static func listen(
        speech: SpeechPresenting,
        text: String?,
        priority: SpeechPriority,
        open: () async -> InputIntent?
    ) async -> InputIntent? {
        if let text { speech.speak(text, priority: priority, onFinish: nil) }
        return await open()
    }
}
