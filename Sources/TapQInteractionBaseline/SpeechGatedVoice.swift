import Foundation
import TapQContracts

/// Wraps the raw voice channel so the microphone is only ever open while the speech
/// engine is fully idle — "the synthesizer must never hear itself", for EVERY utterance,
/// not just a window's own prompt. Notifications from other sessions, "Deferring to the
/// screen." / "AirPods disconnected." announcements, and rapid-navigation TTS backlogs
/// all keep (or take) the mic closed.
///
/// Three behaviors, all fail-open (a wedged synthesizer only leaves voice closed; the
/// window still resolves by gesture, tap, or timeout):
/// - start while speaking → the mic stays closed and opens when the engine drains
/// - speech starts while the mic is open → the recognition session is torn down
///   (transcripts are cumulative, so a heard TTS token could match long after the
///   utterance ends — the whole session must be discarded, not just muted)
/// - the engine drains while the window is still open → a fresh session reopens
@MainActor public final class SpeechGatedVoice: VoiceCommandProviding {
    private let inner: VoiceCommandProviding
    private let activity: SpeechActivitySignaling
    private var handler: (@MainActor (VoiceCommand) -> Void)?
    private let diagnostics: TapQDiagnosticEmitter

    /// Takes ownership of `activity.onSpeakingChange` (single-observer signal).
    public init(wrapping inner: VoiceCommandProviding, activity: SpeechActivitySignaling,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        assert(activity.onSpeakingChange == nil,
               "SpeechGatedVoice takes sole ownership of onSpeakingChange; a second assignment would silently disable the self-hearing guard")
        self.inner = inner
        self.activity = activity
        self.diagnostics = TapQDiagnosticEmitter(category: "SpeechGate", sink: diagnosticSink)
        activity.onSpeakingChange = { [weak self] speaking in
            self?.speakingChanged(speaking)
        }
    }

    public func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
        handler = onCommand
        if activity.isSpeaking {
            diagnostics.record("microphone.held_closed")
        } else {
            startInner()
        }
    }

    public func stop() {
        handler = nil
        inner.stop()
    }

    /// Forwarded rather than folded into `stop()`: the gate owns the microphone's
    /// lifecycle, not the backend's sentence, and only the inner provider knows whether a
    /// response is still speaking. Dropping this to the protocol default would put a
    /// timed-out window back on the `stop()` path and re-flush what the timer was never
    /// meant to touch.
    public func stopUnresolved() {
        handler = nil
        inner.stopUnresolved()
    }

    /// Fired on every edge of the merged speech signal, after the microphone has been dealt
    /// with.
    ///
    /// The gate already owns `activity.onSpeakingChange` — it is a single-observer slot and
    /// taking it is what makes the self-hearing guard reliable — so anything else that needs
    /// the same edge has to be fanned out from here rather than assigned over the top of it.
    /// The wake-word gate is the first such thing (`docs/WAKE_WORD_PLAN.md` §2): TapQ's own
    /// voice is the one competitor for the microphone that no window is holding.
    public var onSpeakingChanged: (@MainActor (Bool) -> Void)?

    private func speakingChanged(_ speaking: Bool) {
        defer { onSpeakingChanged?(speaking) }
        if speaking {
            inner.pauseListening()
        } else if handler != nil {
            diagnostics.record("microphone.reopened")
            startInner()
        }
    }

    private func startInner() {
        inner.start { [weak self] command in
            // The speaking re-check drops matches that raced in on the recognizer's
            // main-actor hop after TTS already started.
            guard let self, let handler = self.handler, !self.activity.isSpeaking else { return }
            handler(command)
        }
    }
}
