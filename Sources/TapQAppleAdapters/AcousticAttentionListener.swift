import Foundation
import TapQContracts
import TapQInteractionBaseline
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)
/// Keeps a microphone open between command windows and hands what it hears to
/// `AcousticAttentionPolicy` — the persistent, on-device, free tier of `--attention acoustic`.
///
/// A funnel and nothing else. Every rule about what counts as speech lives in the policy,
/// which is portable and testable with a fake sample stream; everything here is hardware
/// lifecycle, and it is written the way the rest of this module writes hardware lifecycle by
/// delegating to `MicrophoneEnvelopeSource` — the same `VoiceAudioSourceController`, the same
/// generation-counted teardown, the same route-change invalidation, the same reduction to two
/// doubles on the audio thread with no audio retained.
///
/// ## Why this is not the microphone pump's `onInputLevel`
///
/// `MicrophonePumpVoiceBackend` computes exactly this number and offers exactly this hook,
/// but its microphone opens in `beginUserTurn` and closes in `endUserTurn` — the pump's
/// stated "never always-on" invariant, which is what keeps a cloud session from being fed
/// silence. So the pump's level hook reports what a *window* heard, and the thing this rung
/// needs is the level between windows, where the pump's microphone is deliberately shut.
/// Hence a second, local source that never reaches a network, and the half-duplex rule below
/// so the two are never open at once.
///
/// ## Half-duplex, twice over
///
/// TapQ speaking is handled by the policy: the composition hands it a read of the same
/// engine-plus-player signal `SpeechGatedVoice` gates the microphone on, and while that says
/// TapQ's voice is in the room the level is discarded rather than thresholded.
///
/// A window being open is handled here. ``suspend()`` stops this engine outright rather than
/// merely muting the policy: for the eight seconds a command window runs, that window's own
/// capture is the live one, and a second engine on the same input device would be continuous
/// power and a route to contend for with nothing to buy. ``resume()`` brings it back.
@MainActor public final class AcousticAttentionListener {
    private enum State {
        /// No engine, and nothing arriving. The state before `start` and after a failure.
        case stopped
        /// The engine is up and the policy is deciding.
        case listening
        /// A window owns the microphone. The engine is down and `resume` will bring it back.
        case suspended
    }

    /// The decision half. Exposed so the composition can attach `onOnset` and read
    /// `onsetCount` without this type re-declaring either.
    public let policy: AcousticAttentionPolicy

    private let source: MicrophoneEnvelopeSource
    private let diagnostics: TapQDiagnosticEmitter
    /// The clock the policy's suspensions are stamped with. `systemUptime` deliberately: it
    /// is the clock `AudioClockAnchor` maps every block's host time onto, so a suspension and
    /// the samples around it are on one timeline rather than two that merely look alike.
    private let monotonicNow: @MainActor () -> TimeInterval
    private var state: State = .stopped

    /// The microphone went away and is not coming back on its own — a route change, or a
    /// resume that could not reopen the input.
    ///
    /// Reported rather than handled, because the honest response is a composition decision
    /// and this object is not the composition: a run may want to say so out loud, degrade to
    /// windows it can still open, or stop. What it must not do is leave the wearer talking to
    /// a feature that has silently gone dead, which is the one outcome this closure exists to
    /// prevent.
    public var onUnavailable: (@MainActor (String) -> Void)?

    public init(
        policy: AcousticAttentionPolicy,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.policy = policy
        self.source = MicrophoneEnvelopeSource(diagnosticSink: diagnosticSink)
        self.diagnostics = TapQDiagnosticEmitter(
            category: "AcousticListen", sink: diagnosticSink)
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
    }

    /// Whether the engine is up and the policy is deciding right now.
    public var isListening: Bool { state == .listening }

    /// Opens the microphone for the run.
    ///
    /// Throws where the input never opened, unlike ``resume()``, which reports through
    /// ``onUnavailable``. The difference is who is asking: this is called while the
    /// composition is still assembling itself and can still refuse to start, and a run that
    /// asked to always listen and cannot should say so before the wearer starts talking to
    /// it.
    public func start() throws {
        guard state == .stopped else { return }
        try open()
        diagnostics.record("listening.started")
    }

    /// Closes the microphone for good. Idempotent.
    public func stop() {
        guard state != .stopped else { return }
        policy.setSuspended(true, at: monotonicNow())
        source.stop()
        state = .stopped
        diagnostics.record("listening.stopped")
    }

    /// Hands the microphone to a command window. Idempotent, and a no-op once stopped.
    public func suspend() {
        guard state == .listening else { return }
        policy.setSuspended(true, at: monotonicNow())
        source.stop()
        state = .suspended
        diagnostics.record("listening.suspended")
    }

    /// Takes the microphone back when the window closes.
    ///
    /// A reopen that fails leaves this stopped and calls ``onUnavailable``: a window closing
    /// is not a moment a composition can throw from, and always-listening that quietly stops
    /// listening is the failure this rung must not have.
    public func resume() {
        guard state == .suspended else { return }
        do {
            try open()
            diagnostics.record("listening.resumed")
        } catch {
            state = .stopped
            let detail = String(describing: error)
            diagnostics.record("listening.resume_failed", level: .warning,
                               fields: ["error": detail])
            onUnavailable?(detail)
        }
    }

    // MARK: - Internals

    /// Starts the envelope source and, only once it is actually running, tells the policy the
    /// microphone is its again. Ordered that way deliberately: un-suspending first would put
    /// the policy in a state where a failed start leaves it waiting for samples that will
    /// never arrive, and unable to tell that from a quiet room.
    private func open() throws {
        try source.start(
            onTrack: { [weak self] track in
                self?.diagnostics.record("track", fields: [
                    "sample_rate": "\(Int(track.sampleRate))",
                    "block_frames": "\(track.blockFrames)",
                ])
            },
            onBlock: { [weak self] block in
                self?.policy.noteLevel(block.rms, at: block.timestamp)
            },
            onInvalidation: { [weak self] failure in
                self?.invalidated(failure)
            }
        )
        state = .listening
        policy.setSuspended(false, at: monotonicNow())
    }

    /// The route changed or the input died. `MicrophoneEnvelopeSource` has already torn
    /// itself down by the time this runs, so there is nothing to stop — only a policy to
    /// suspend and a composition to tell.
    private func invalidated(_ failure: MicrophoneEnvelopeFailure) {
        guard state != .stopped else { return }
        policy.setSuspended(true, at: monotonicNow())
        state = .stopped
        diagnostics.record("listening.invalidated", level: .warning, fields: [
            "stage": failure.stage.rawValue,
            "error": failure.detail,
        ])
        onUnavailable?(failure.description)
    }
}
#endif
