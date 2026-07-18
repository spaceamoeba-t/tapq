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

    private func speakingChanged(_ speaking: Bool) {
        if speaking {
            inner.stop()
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
