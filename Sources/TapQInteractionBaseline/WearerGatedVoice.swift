import Foundation
import TapQContracts

/// Wraps the raw voice channel so a matched command only resolves a window when the
/// *wearer* is the one who spoke it. The microphone hears the whole room; the in-ear IMU
/// only hears the jaw it is attached to, so attribution is decided by motion, never audio.
///
/// Delivery policy — a command passes through iff either:
/// - the wearer was speaking at any point within the trailing attribution window
///   (recognition latency means a match lands hundreds of milliseconds after the speech
///   that produced it, so the window looks *backwards* from delivery time), or
/// - `signal.isSignalAvailable` is false — fail open. A degraded or absent analyzer must
///   reproduce today's shipped behavior verbatim; attribution may only ever remove
///   commands it is confident about, never add a new way for a window to hang.
///
/// This wrapper never opens or closes the inner microphone — that is `SpeechGatedVoice`'s
/// job, and duplicating it here would fight it. Documented stacking order at composition
/// time is `SpeechGatedVoice(wrapping: WearerGatedVoice(wrapping: rawVoice, signal:),
/// activity:)`: TTS gating owns the mic lifecycle on the outside, attribution filters what
/// survives on the inside.
///
/// Not wired into the live runtime this milestone (same precedent as
/// `swipeDetectionEnabled: false`): promotion waits on the capture study that validates
/// the detector's thresholds against ground truth.
@MainActor public final class WearerGatedVoice: VoiceCommandProviding, WearerAttributionChecking {
    /// Generous by design: an under-wide window silently drops real commands, while an
    /// over-wide one only lets through speech the wearer produced moments ago anyway.
    public nonisolated static let defaultAttributionWindow: TimeInterval = 2.0

    private let inner: VoiceCommandProviding
    private let signal: WearerSpeechSignaling
    private let attributionWindow: TimeInterval
    private let monotonicNow: () -> TimeInterval
    private let diagnostics: TapQDiagnosticEmitter
    private var handler: (@MainActor (VoiceCommand) -> Void)?
    /// Monotonic timestamp of the most recent moment the wearer was known to be speaking.
    /// Survives `stop()`: speech that ended just before a window opened is still the
    /// wearer's, and the recognizer's latency is exactly why it arrives late.
    private var lastWearerSpeechAt: TimeInterval?

    /// Takes ownership of `signal.onWearerSpeakingChange` (single-observer signal).
    public init(wrapping inner: VoiceCommandProviding,
                signal: WearerSpeechSignaling,
                attributionWindow: TimeInterval = WearerGatedVoice.defaultAttributionWindow,
                monotonicNow: @escaping () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        assert(signal.onWearerSpeakingChange == nil,
               "WearerGatedVoice takes sole ownership of onWearerSpeakingChange; a second assignment would silently disable voice attribution")
        self.inner = inner
        self.signal = signal
        self.attributionWindow = attributionWindow
        self.monotonicNow = monotonicNow
        self.diagnostics = TapQDiagnosticEmitter(category: "WearerGate", sink: diagnosticSink)
        if signal.isWearerSpeaking {
            // Composed mid-utterance: the transition already happened, so nothing would
            // ever record it.
            lastWearerSpeechAt = monotonicNow()
        }
        signal.onWearerSpeakingChange = { [weak self] speaking in
            self?.wearerSpeakingChanged(speaking)
        }
    }

    public func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
        handler = onCommand
        inner.start { [weak self] command in
            guard let self, let handler = self.handler else { return }
            guard self.isAttributedToWearer() else { return }
            handler(command)
        }
    }

    public func stop() {
        handler = nil
        inner.stop()
    }

    public func pauseListening() {
        handler = nil
        inner.pauseListening()
    }

    /// Attribution has nothing to say about how a window ended; the reason is relayed
    /// unchanged so the provider underneath still sees a timeout as a timeout.
    public func stopUnresolved() {
        handler = nil
        inner.stopUnresolved()
    }

    /// The same trailing window, read fail-closed for the instruction path.
    ///
    /// The arithmetic below is a deliberate second copy of `isAttributedToWearer()` rather
    /// than a shared helper the two callers parameterize. A shared one would put the
    /// approval channel's fail-open answer and the instruction channel's fail-closed answer
    /// on the same line of code, one boolean apart — and the whole point of the split is
    /// that no future edit should be able to flip one by touching the other. Two short
    /// bodies that disagree in public are safer than one clever body that agrees in
    /// private.
    ///
    /// Reading this does not consume the attribution or move the window: it is a question
    /// about the recent past, and asking it twice in one dictation (once to open the flow,
    /// once for the sentence that follows) is exactly the intended use.
    public var isWearerAttributedNow: Bool {
        guard signal.isSignalAvailable else {
            diagnostics.record("attribution.query_signal_unavailable")
            return false
        }
        if signal.isWearerSpeaking { return true }
        let now = monotonicNow()
        if let last = lastWearerSpeechAt, now - last <= attributionWindow { return true }
        let sinceSpeech = lastWearerSpeechAt.map { String(format: "%.3f", now - $0) } ?? "never"
        diagnostics.record("attribution.query_nonwearer",
                           fields: ["since_wearer_speech_seconds": sinceSpeech,
                                    "attribution_window_seconds": String(format: "%.3f", attributionWindow)])
        return false
    }

    private func wearerSpeakingChanged(_ speaking: Bool) {
        // Both edges stamp the clock: the rising edge so a command matched during a still
        // ongoing utterance has an anchor even if the signal wedges, the falling edge so
        // the trailing window is measured from when the wearer actually stopped.
        lastWearerSpeechAt = monotonicNow()
    }

    private func isAttributedToWearer() -> Bool {
        guard signal.isSignalAvailable else {
            diagnostics.record("command.passed_signal_unavailable")
            return true
        }
        if signal.isWearerSpeaking { return true }
        let now = monotonicNow()
        if let last = lastWearerSpeechAt, now - last <= attributionWindow { return true }
        let sinceSpeech = lastWearerSpeechAt.map { String(format: "%.3f", now - $0) } ?? "never"
        diagnostics.record("command.rejected_nonwearer",
                           fields: ["since_wearer_speech_seconds": sinceSpeech,
                                    "attribution_window_seconds": String(format: "%.3f", attributionWindow)])
        return false
    }
}
