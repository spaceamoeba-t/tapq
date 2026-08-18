import Foundation
import TapQContracts

/// Turns the utterances that exist to get the wearer's attention into a short cue, and
/// leaves the ones that answer the wearer as speech.
///
/// Composed only under `--quiet`, so a run without the flag holds no reference to this type
/// and every utterance takes exactly the path it took before quiet mode existed.
///
/// **The split is by role, not by priority, and priority alone cannot see it.** A prompt and
/// a recall answer are both spoken at `.approval` through the same `BargeIn.listen` call, so
/// a decorator that keyed on priority would silence "Claude Code: run the test suite. 2 more
/// waiting." along with the prompt — and a wearer who asks a question out loud and hears a
/// chime back has been given a worse answer than silence. What separates them is *who
/// started the exchange*, and the runtime is the only party that knows: it opens the window,
/// so it arms the prompt.
///
/// The rules, in full:
///
/// * `.notification` — deferrals, motion-loss notices, the coordinator's status lines.
///   Always a notification cue. Nothing at this priority is an answer to a question the
///   wearer asked.
/// * `.approval` **while armed** — the first thing said in a freshly-opened window, which is
///   the request itself. A prompt cue, and the arming is spent.
/// * `.approval` **unarmed** — everything else inside the window: recall answers, detail
///   read-outs, dictation read-backs, the "say yes to confirm" cue of a second confirmation
///   pass. Spoken.
/// * `.progress` — spoken, untouched. Nothing routes through it today.
///
/// Resolution semantics are not this type's business and it changes none of them: a chimed
/// prompt is answered by the same nod, in the same window, on the same deadline. What the
/// wearer loses is the sentence, and what they have instead is "status" — which quiet mode
/// answers out loud, on purpose.
@MainActor public final class QuietSpeech: SpeechPresenting {
    private let inner: any SpeechPresenting
    private let playCue: @MainActor (NotificationCue) -> Void
    /// Whether the next `.approval` utterance is a freshly-opened window's prompt.
    private var promptArmed = false

    /// - Parameters:
    ///   - inner: the presenter an unsuppressed utterance is forwarded to — the speech
    ///     engine, or the backend-preferred decorator wrapped around it.
    ///   - playCue: plays one cue. A closure rather than a protocol because the only
    ///     implementation lives in the Apple adapter layer, which this target cannot see.
    public init(wrapping inner: any SpeechPresenting,
                playCue: @escaping @MainActor (NotificationCue) -> Void) {
        self.inner = inner
        self.playCue = playCue
    }

    /// Declares that a request window is about to open, so its first spoken line is a
    /// prompt rather than an answer.
    ///
    /// Idempotent and unpaired: there is no `disarm`, because the arming is consumed by the
    /// utterance it describes and a window that somehow says nothing simply leaves it set
    /// for the next one — which is also a prompt. Arming twice is arming once.
    public func armPrompt() {
        promptArmed = true
    }

    /// Whether a prompt cue is still owed. Read-only, for tests and diagnostics.
    public var isPromptArmed: Bool { promptArmed }

    public func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
        switch priority {
        case .notification:
            chime(.notification, onFinish: onFinish)
        case .approval where promptArmed:
            promptArmed = false
            chime(.prompt, onFinish: onFinish)
        case .approval, .progress:
            inner.speak(text, priority: priority, onFinish: onFinish)
        }
    }

    public func stopAll() {
        inner.stopAll()
    }

    /// Plays the cue and completes immediately.
    ///
    /// `onFinish` is called synchronously rather than when the tone drains, because every
    /// caller uses it to mean "the channel is free again" and a cue occupies a separate
    /// engine that never held the channel in the first place. Waiting on the tone would add
    /// a hundred milliseconds to the front of an input window for no gain.
    private func chime(_ cue: NotificationCue, onFinish: (() -> Void)?) {
        playCue(cue)
        onFinish?()
    }
}
