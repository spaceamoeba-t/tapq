import Foundation
import TapQContracts

/// Whether a full re-speak still fits: can `text` be asked, and the answer heard, before
/// `deadline`?
///
/// One function because two controllers ask it, and a drift between them would be a runtime
/// where `repeat` is guarded inside an approval and unguarded inside a selection — the sort
/// of difference nobody notices until a wearer is standing in it.
///
/// The measurement is of the sentence actually in hand, not of the presenter's declared
/// maximum. That is the point of having it at all: the entry floor is a promise made before
/// any text exists, and `details` returns the request's own `detail` string, which no cap in
/// this package bounds.
///
/// `false` is not "say it anyway, shorter". There is no shorter version of a question, and a
/// question asked into a window that ends mid-sentence is recorded as the wearer having
/// nothing to say about something they never heard. The caller refuses, out loud.
@MainActor func canRespeak(_ text: String,
                           before deadline: ContinuousClock.Instant,
                           now: ContinuousClock.Instant,
                           on path: SpokenPace.Path,
                           kind: String,
                           diagnostics: TapQDiagnosticEmitter) -> Bool {
    let remaining = deadline.seconds(after: now)
    let needed = SpokenPace.viableSeconds(asking: text, on: path)
    guard remaining >= needed else {
        diagnostics.record("respeak.insufficient_budget", fields: [
            "kind": kind,
            "characters": "\(text.count)",
            "remaining": secondsField(remaining),
            "needed": secondsField(needed),
            "pace": path.rawValue,
        ])
        return false
    }
    return true
}

/// One decimal place, so a diagnostic line is readable and two of them are comparable.
func secondsField(_ value: TimeInterval) -> String {
    String(format: "%.1f", value)
}

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
public enum SpokenPace {
    /// Which of TapQ's two voices is doing the speaking.
    ///
    /// One number cannot carry this once the question is "is there time to *ask* something".
    /// The paces differ by about a factor of two, so a floor derived from the fast voice
    /// refuses almost nothing on the slow one — and the slow one is exactly where a
    /// maximum-length prompt outlasts the margin that was supposed to protect it.
    public enum Path: String, Sendable, Equatable {
        /// The backend voice (`--voice-backend openai-realtime`).
        case realtime
        /// `AVSpeechSynthesizer`, the local voice.
        case apple

        /// Characters of ordinary prose per second, measured and then shortened by a fifth
        /// — the same margin `charactersPerSecond` carries and for the same reason: erring
        /// long spends a few seconds of an already-open window, erring short costs the
        /// wearer the answer they were in the middle of giving.
        var charactersPerSecond: Double {
            switch self {
            case .realtime: return 23   // ~29 measured
            case .apple: return 12      // ~15 measured — `charactersPerSecond` below, same sum
            }
        }
    }

    /// What a composition that has not said which voice it speaks with is assumed to use.
    ///
    /// The slower of the two, deliberately. Guessing fast makes TapQ ask questions the
    /// wearer cannot answer, which is the bug this whole file exists to close; guessing slow
    /// makes it decline a question early and out loud, which the wearer can hear and act on.
    public static let defaultPath = Path.apple

    /// Characters of ordinary prose per second of synthesized speech.
    ///
    /// ~150 words per minute at ~5.5 characters plus a space is a shade under 15 characters
    /// a second; 12 is that with the margin the paragraph above argues for, and covers the
    /// slower of the two voices TapQ speaks with.
    static let charactersPerSecond: Double = Path.apple.charactersPerSecond

    /// Silence the wearer is owed after their last word, before anything commits their turn:
    /// the detector's hangover plus `WearerTurnCoordinator`'s endpoint delay. An answering
    /// window budgeted without it charges the wearer for a second they cannot speak in.
    /// One value with `WindowClock.commitAllowance` by construction — both read the same
    /// mirrored hangover, which `WindowClock` owns (and a detection-side test pins).
    static let endpointingSeconds: TimeInterval = WindowClock.commitAllowance

    /// The one in-module home of the restated `WearerSpeechConfig.hangoverSeconds` default
    /// is `WindowClock.detectorHangover`; see its comment for why it is a mirror.
    static let detectorHangoverSeconds: TimeInterval = WindowClock.detectorHangover

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

    // MARK: - Viability: is there enough budget to even ask?

    /// The least budget in which an utterance of `characters` can be **asked and answered**.
    ///
    /// Three terms, and the bug was that the old hand-picked 12 seconds contained none of
    /// them explicitly:
    ///
    /// 1. **The asking.** TapQ holds the microphone shut for the whole of its own playback,
    ///    so every character of the question is a second the wearer cannot use.
    /// 2. **The answering.** `answeringSeconds` — hear the end of the sentence, take a
    ///    breath, say the word.
    /// 3. **The committing.** `endpointingSeconds` sits between the wearer's last syllable
    ///    and the turn closing; a window that ends on the syllable ends before the answer.
    ///
    /// Twelve seconds covered (2) and (3) and about four seconds of (1), which is why the
    /// presenters' own maximum prompts — 200-plus characters, seventeen seconds at the Apple
    /// pace — sailed past it and were spoken into a window that could not carry them.
    static func viableSeconds(utteranceCharacters characters: Int,
                              on path: Path = defaultPath,
                              answering: TimeInterval = answeringSeconds) -> TimeInterval {
        Double(characters) / path.charactersPerSecond + answering + endpointingSeconds
    }

    /// The same, for an utterance in hand.
    ///
    /// Nothing to say needs no asking budget: a turn with no utterance is a *listening* turn,
    /// which takes whatever is left of the window and is owed nothing — the distinction
    /// `TurnBudget` opens this file with.
    static func viableSeconds(asking utterance: String?,
                              on path: Path = defaultPath,
                              answering: TimeInterval = answeringSeconds) -> TimeInterval {
        guard let utterance, !utterance.isEmpty else { return 0 }
        return viableSeconds(utteranceCharacters: utterance.count,
                             on: path,
                             answering: answering)
    }

    /// The shortest listen window a run may be configured with (`--timeout`).
    ///
    /// Public because the command line has to refuse an unusable one at parse time rather
    /// than let every prompt of the run turn out to be structurally unanswerable, and the
    /// CLI cannot reach the internals above.
    ///
    /// It is the *widest* of the two flows' floors, at the slower voice: `--timeout` is one
    /// number for a run that does not yet know which kind of question it will be asked, and
    /// a floor sized for approvals would still leave every selection unanswerable. Rounded
    /// up to the second so the number in the refusal is the number that is enforced.
    public static let minimumListenSeconds: TimeInterval = (viableSeconds(
        utteranceCharacters: max(DefaultApprovalRequestPresenter.maximumPromptCharacters,
                                 SelectionController.maximumPromptCharacters)
    )).rounded(.up)
}
