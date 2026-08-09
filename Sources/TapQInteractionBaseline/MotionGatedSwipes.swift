import Foundation
import TapQContracts

/// Wraps the volume-swipe channel so it is only ever attached while the motion device it
/// belongs to is actually present.
///
/// Stem swipes are read from the *default output device's* volume, which on a Mac with no
/// AirPods connected is the built-in speaker. Left ungated, every volume-key press during
/// a selection window would be read as next/previous — the user changes the volume and the
/// selection moves. Eligibility is the fix, and it is a function rather than a flag because
/// `SelectionArbiter.begin/finish` start and stop swipes once per window: AirPods connected
/// mid-session make the very next window eligible, with nothing to recompose.
///
/// Fail-closed on purpose, and the only decorator here that is: `SpeechGatedVoice` and
/// `WearerGatedVoice` fail open because a wedged signal must never remove a way to answer,
/// while a swipe channel that survives its device does not remove an answer — it invents
/// one the user did not give.
@MainActor public final class MotionGatedSwipes: VolumeSwipeProviding {
    private let inner: VolumeSwipeProviding
    private let isEligible: @MainActor () -> Bool
    private let diagnostics: TapQDiagnosticEmitter
    /// `stop()` must not reach an inner provider that was never started: the concrete
    /// detector installs and removes a CoreAudio property listener, and unbalanced
    /// teardown is exactly the kind of thing that only shows up on someone else's Mac.
    private var innerStarted = false

    /// `isEligible` is consulted on every `start`, so it must answer for the moment it is
    /// called rather than for composition time.
    public init(wrapping inner: VolumeSwipeProviding,
                isEligible: @escaping @MainActor () -> Bool,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.inner = inner
        self.isEligible = isEligible
        self.diagnostics = TapQDiagnosticEmitter(category: "SwipeGate", sink: diagnosticSink)
    }

    public func start(onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void) {
        guard isEligible() else {
            diagnostics.record(
                "swipes.suppressed",
                fields: ["reason": "motion_unavailable"]
            )
            return
        }
        innerStarted = true
        inner.start(onSwipe: onSwipe)
    }

    public func stop() {
        guard innerStarted else { return }
        innerStarted = false
        inner.stop()
    }
}
