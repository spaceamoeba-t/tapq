import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The one question the realtime degrade path asks, and the reason it is not the same
/// question `WearerSpeechSignaling.isSignalAvailable` answers.
///
/// Availability describes the last few hundred milliseconds. Between windows the motion
/// stream is stopped, so it reads false on a run whose AirPods are working perfectly — at
/// exactly the moment the decision has to be made. These tests pin the difference: the
/// default is optimism about the *run*, and only real evidence retracts it.
@MainActor
final class WearerTurnSignalLivenessTests: XCTestCase {

    private final class FakeSignal: WearerSpeechSignaling {
        var isWearerSpeaking = false
        var isSignalAvailable: Bool
        var onWearerSpeakingChange: (@MainActor (Bool) -> Void)?

        init(isSignalAvailable: Bool = false) {
            self.isSignalAvailable = isSignalAvailable
        }

        /// A quiet↔speaking edge, as the source broadcasts it.
        func transition(to speaking: Bool) {
            isWearerSpeaking = speaking
            onWearerSpeakingChange?(speaking)
        }
    }

    /// No `--imu-turn-control`: there is no coordinator listening, so nothing on TapQ's side
    /// would ever commit the turn and the answer is no, permanently.
    func testARunWithoutTheFlagIsNeverLive() {
        XCTAssertFalse(WearerTurnSignalLiveness(signal: nil).isLive)
    }

    /// A flagged run starts live even though no sample has arrived yet. The alternative —
    /// starting degraded and upgrading once samples flow — would put the *first* window of
    /// every working AirPods run on the remote endpoint's VAD, which is a behavior change to
    /// the path the carve-out is explicitly not for.
    func testAFlaggedRunStartsLiveBeforeAnySampleArrives() {
        let signal = FakeSignal(isSignalAvailable: false)
        XCTAssertTrue(WearerTurnSignalLiveness(signal: signal).isLive)
    }

    /// The availability lie: macOS reports AirPods that are paired but sitting in their case
    /// as available, and the only thing that ever discovers it is a stream that never
    /// produces a sample. That discovery arrives here as `noteMotionUnavailable`.
    func testAConfirmedMotionLossRetractsTheOptimism() {
        let liveness = WearerTurnSignalLiveness(signal: FakeSignal())
        liveness.noteMotionUnavailable()
        XCTAssertFalse(liveness.isLive)
    }

    /// Staleness is not absence. Between two windows the last sample ages out and
    /// `isSignalAvailable` goes false; that must not degrade the next window, or a working
    /// pair of AirPods would hand endpointing away every time the wearer paused.
    func testAStaleSignalDoesNotCountAsALoss() {
        let signal = FakeSignal(isSignalAvailable: true)
        let liveness = WearerTurnSignalLiveness(signal: signal)
        XCTAssertTrue(liveness.isLive)

        signal.isSignalAvailable = false
        XCTAssertTrue(liveness.isLive, "the stream stopped with the window, not with the hardware")
    }

    /// The wearer puts their AirPods in mid-run. Samples reach the source during the window,
    /// and the next window is TapQ's again — without anything having to watch for a
    /// reconnect.
    func testAReturningSampleRestoresTheSignal() {
        let signal = FakeSignal(isSignalAvailable: false)
        let liveness = WearerTurnSignalLiveness(signal: signal)
        liveness.noteMotionUnavailable()
        XCTAssertFalse(liveness.isLive)

        signal.isSignalAvailable = true
        XCTAssertTrue(liveness.isLive)
    }

    /// The same recovery through the other door: a transition observed while the signal is
    /// available clears the loss, so a query landing between windows — when availability has
    /// already aged out again — still answers yes.
    func testATransitionOnALiveSignalRearmsTheRun() {
        let signal = FakeSignal(isSignalAvailable: false)
        let liveness = WearerTurnSignalLiveness(signal: signal)
        liveness.noteMotionUnavailable()

        signal.isSignalAvailable = true
        signal.transition(to: true)
        signal.isSignalAvailable = false

        XCTAssertTrue(liveness.isLive)
    }

    /// A transition on a signal that cannot be trusted proves nothing and must not re-arm.
    func testATransitionOnAnUnavailableSignalDoesNotRearm() {
        let signal = FakeSignal(isSignalAvailable: false)
        let liveness = WearerTurnSignalLiveness(signal: signal)
        liveness.noteMotionUnavailable()

        signal.transition(to: true)

        XCTAssertFalse(liveness.isLive)
    }

    func testRepeatedLossReportsAreIdempotent() {
        let liveness = WearerTurnSignalLiveness(signal: FakeSignal())
        liveness.noteMotionUnavailable()
        liveness.noteMotionUnavailable()
        XCTAssertFalse(liveness.isLive)
    }
}
