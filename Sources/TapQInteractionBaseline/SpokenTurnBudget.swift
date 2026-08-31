import Foundation

/// How much open microphone one turn of a windowed flow needs.
///
/// The distinction is between a turn that is *listening* and a turn that is *asking*. A
/// listening turn takes whatever is left of the window: nothing has been put to the wearer,
/// so nothing is owed to them. A turn that asks a question is different in kind — TapQ holds
/// the microphone closed for the whole of its own playback (`SpeechGatedVoice`), so a listen
/// sized to the window's residue can expire while the question is still being asked, and the
/// wearer is recorded as silent about a sentence they never got to answer.
///
/// That is not hypothetical. On hardware, 2026-08-30: a 125-character read-back was queued,
/// the arbiter re-listened with `timeout=1.96` left in the window, the microphone was held
/// closed for the drain, and the instruction was discarded `reason=silence` — every time,
/// structurally, whenever the read-back outlasted the residue.
enum TurnBudget: Equatable {
    /// Whatever is left of the caller's window, capped as the caller always capped it.
    case remainingWindow
    /// The turn asks something the wearer must answer. The listen must cover the utterance's
    /// own playback *and* leave `answering` seconds of open microphone after it, even when
    /// that outlives what is left of the window.
    case afterSpeaking(answering: TimeInterval)

    /// The default answering budget, for the callers that have no reason to name their own.
    static let answering = TurnBudget.afterSpeaking(answering: SpokenPace.answeringSeconds)
}

/// Deterministic estimates of how long TapQ's own speech holds the channel.
///
/// ## Why an estimate and not a measurement
///
/// Nothing in this layer can be told when an utterance has actually drained.
/// `SpeechPresenting.speak`'s `onFinish` fires when the *backend accepts* the sentence, not
/// when its audio ends (`BackendSpeechSink` documents exactly that: the wire has no finish
/// callback to relay). The one true drain signal — `SpeechActivitySignaling` — is a
/// single-observer slot owned by `SpeechGatedVoice` at composition time, and even with a
/// multicast it would not answer this question: on the realtime path playback starts
/// hundreds of milliseconds *after* acceptance, so "not speaking yet" and "already drained"
/// are the same reading at the moment a listen opens.
///
/// So the pace is estimated from the text, deterministically, where it can be reasoned about
/// and tested with a virtual clock. It deliberately errs long: an over-long listen costs an
/// already-open window a few seconds that a wearer can end by answering, while a short one
/// costs them the sentence they were dictating.
enum SpokenPace {
    /// Characters of ordinary prose per second of synthesized speech.
    ///
    /// ~150 words per minute at ~5.5 characters plus a space is a shade under 15 characters
    /// a second; 12 is that with the margin the paragraph above argues for, and covers the
    /// slower of the two voices TapQ speaks with.
    static let charactersPerSecond: Double = 12

    /// How long the wearer gets to answer once the question has finished being asked.
    ///
    /// Long enough to hear the end of a read-back, take a breath, and say "yes" — and short
    /// enough that a window nobody answers still closes while the wearer is standing there.
    static let answeringSeconds: TimeInterval = 6

    /// How long `text` will be sounding, in seconds. Nothing to say drains instantly.
    static func drainSeconds(of text: String?) -> TimeInterval {
        guard let text, !text.isEmpty else { return 0 }
        return Double(text.count) / charactersPerSecond
    }

    /// The listen a spoken question needs: never shorter than the window's own residue, and
    /// never shorter than the question's playback plus a real answering window.
    ///
    /// The `max` is the whole of it. Where the window has time, this is what the caller
    /// always did; where it does not, the turn is extended by exactly what it takes for the
    /// question to be answerable at all. A confirmation the wearer structurally cannot give
    /// is not a shorter interaction, it is a lost one.
    static func listenSeconds(asking utterance: String?,
                              remaining: TimeInterval,
                              answering: TimeInterval = answeringSeconds) -> TimeInterval {
        max(remaining, drainSeconds(of: utterance) + answering)
    }
}
