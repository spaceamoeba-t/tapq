import AVFoundation
import XCTest
@testable import TapQAppleAdapters
import TapQAudioCaptureBridge
import TapQAudioCaptureBridgeTestSupport

/// The RD4 voice-processing spike: the bridge's enable-before-tap ordering, the shared-engine
/// hosting seam, and the one configuration change a voice-processing start is allowed to
/// survive. Hardware assertions are skipped when the host has no usable audio device; the
/// logic they guard is proved by the parts above them, which touch nothing.
@MainActor
final class VoiceProcessingSeamTests: XCTestCase {

    // MARK: - Transition gate

    func testAnUnarmedGateForgivesNothing() async {
        var gate = VoiceProcessingTransitionGate(grace: 1.0)
        XCTAssertFalse(gate.isArmed)
        XCTAssertFalse(gate.tolerates(at: 0))
    }

    func testAnArmedGateForgivesTheFirstChangeInsideTheGrace() async {
        var gate = VoiceProcessingTransitionGate(grace: 1.0)
        gate.arm(at: 100)
        XCTAssertTrue(gate.tolerates(at: 100.4))
    }

    func testTheGateForgivesExactlyOneChange() async {
        var gate = VoiceProcessingTransitionGate(grace: 1.0)
        gate.arm(at: 100)
        XCTAssertTrue(gate.tolerates(at: 100.1))
        XCTAssertFalse(gate.tolerates(at: 100.2),
                       "the second change of a session is a real route change")
    }

    func testTheGateDoesNotForgiveAChangeAfterTheGrace() async {
        var gate = VoiceProcessingTransitionGate(grace: 1.0)
        gate.arm(at: 100)
        XCTAssertFalse(gate.tolerates(at: 101.001))
        XCTAssertFalse(gate.isArmed, "a late change disarms the gate as well")
    }

    func testDisarmingRevokesTheForgiveness() async {
        var gate = VoiceProcessingTransitionGate(grace: 1.0)
        gate.arm(at: 100)
        gate.disarm()
        XCTAssertFalse(gate.tolerates(at: 100.1))
    }

    // MARK: - Source-level tolerance

    private func postConfigurationChange(for capture: TapQAudioCaptureEngine) async {
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: capture.engine)
        for _ in 0..<8 { await Task.yield() }
    }

    func testVoiceProcessingOffKeepsAConfigurationChangeFatal() async {
        let capture = TapQAudioCaptureEngine()
        let source = AVAudioEngineVoiceAudioSource(capture: capture)
        var failures: [VoiceAudioSourceFailure] = []
        source.beginObservingForTesting { failures.append($0) }

        await postConfigurationChange(for: capture)

        XCTAssertEqual(failures.map(\.stage), [.configurationChanged])
        XCTAssertFalse(capture.voiceProcessingEnabled,
                       "the bridge flag stays off unless the source was built with it on")
        source.stop()
    }

    func testVoiceProcessingOnSurvivesTheTransitionChange() async {
        var clock: TimeInterval = 100
        let capture = TapQAudioCaptureEngine()
        let source = AVAudioEngineVoiceAudioSource(
            capture: capture,
            voiceProcessingEnabled: true,
            voiceProcessingTransitionGrace: 1.0,
            now: { clock }
        )
        var failures: [VoiceAudioSourceFailure] = []
        var transitions = 0
        source.onVoiceProcessingTransition = { transitions += 1 }
        source.beginObservingForTesting { failures.append($0) }

        clock = 100.2
        await postConfigurationChange(for: capture)

        XCTAssertTrue(capture.voiceProcessingEnabled, "the flag reached the bridge")
        XCTAssertEqual(transitions, 1)
        XCTAssertEqual(failures, [], "the window survives its own voice-processing transition")
        source.stop()
    }

    func testASecondChangeUnderVoiceProcessingIsStillFatal() async {
        var clock: TimeInterval = 100
        let capture = TapQAudioCaptureEngine()
        let source = AVAudioEngineVoiceAudioSource(
            capture: capture,
            voiceProcessingEnabled: true,
            voiceProcessingTransitionGrace: 1.0,
            now: { clock }
        )
        var failures: [VoiceAudioSourceFailure] = []
        source.beginObservingForTesting { failures.append($0) }

        clock = 100.1
        await postConfigurationChange(for: capture)
        clock = 100.2
        await postConfigurationChange(for: capture)

        XCTAssertEqual(failures.map(\.stage), [.configurationChanged])
        source.stop()
    }

    func testALateChangeUnderVoiceProcessingIsStillFatal() async {
        var clock: TimeInterval = 100
        let capture = TapQAudioCaptureEngine()
        let source = AVAudioEngineVoiceAudioSource(
            capture: capture,
            voiceProcessingEnabled: true,
            voiceProcessingTransitionGrace: 1.0,
            now: { clock }
        )
        var failures: [VoiceAudioSourceFailure] = []
        source.beginObservingForTesting { failures.append($0) }

        clock = 130   // the wearer changed headphones half a minute in
        await postConfigurationChange(for: capture)

        XCTAssertEqual(failures.map(\.stage), [.configurationChanged])
        source.stop()
    }

    func testStoppingDisarmsTheGateSoALaterWindowIsNotForgiven() async {
        var clock: TimeInterval = 100
        let capture = TapQAudioCaptureEngine()
        let source = AVAudioEngineVoiceAudioSource(
            capture: capture,
            voiceProcessingEnabled: true,
            voiceProcessingTransitionGrace: 1.0,
            now: { clock }
        )
        var failures: [VoiceAudioSourceFailure] = []
        source.beginObservingForTesting { failures.append($0) }
        source.stop()

        // A second window arms the gate again; that one change is the new transition.
        source.beginObservingForTesting { failures.append($0) }
        clock = 100.3
        await postConfigurationChange(for: capture)
        clock = 100.4
        await postConfigurationChange(for: capture)

        XCTAssertEqual(failures.map(\.stage), [.configurationChanged],
                       "one forgiveness per window, not one per process")
        source.stop()
    }

    // MARK: - Bridge: enable before tap install

    func testVoiceProcessingIsOffByDefaultAndRoundTrips() async {
        let capture = TapQAudioCaptureEngine()
        XCTAssertFalse(capture.voiceProcessingEnabled)
        XCTAssertFalse(capture.tapInstalled)
        capture.voiceProcessingEnabled = true
        XCTAssertTrue(capture.voiceProcessingEnabled)
    }

    func testAFailedVoiceProcessingTransitionAbortsBeforeTheTapIsInstalled() async {
        let capture = TapQStubbedVoiceProcessingCaptureEngine()
        capture.voiceProcessingEnabled = true
        capture.failsVoiceProcessing = true

        var error: NSError?
        let started = TapQAudioCaptureEngineStart(
            capture, 1024, { _, _ in XCTFail("a failed start must not deliver audio") }, &error)

        XCTAssertFalse(started)
        XCTAssertEqual(error?.userInfo[TapQAudioCaptureFailureStageKey] as? String,
                       "voice_processing")
        XCTAssertEqual(capture.voiceProcessingCallCount, 1)
        XCTAssertFalse(capture.tapWasInstalledWhenApplied,
                       "voice processing must settle before anything touches the node")
        XCTAssertFalse(capture.tapInstalled, "an aborted start leaves the node clean")
    }

    /// The seam is the first step of the start, so a failing transition returns before the
    /// bridge ever resolves the input node — which is also why this whole file can run in a
    /// test host that must never open the microphone.
    func testAFailedTransitionReturnsBeforeTheInputNodeIsEvenResolved() async {
        let capture = TapQStubbedVoiceProcessingCaptureEngine()
        capture.voiceProcessingEnabled = true
        capture.failsVoiceProcessing = true

        var error: NSError?
        _ = TapQAudioCaptureEngineStart(capture, 1024, { _, _ in }, &error)

        XCTAssertNil(error?.userInfo[NSUnderlyingErrorKey],
                     "the failure is the stub's own, not a downstream audio-setup error")

        var stopError: NSError?
        XCTAssertTrue(TapQAudioCaptureEngineStop(capture, &stopError),
                      "an aborted start still tears down cleanly")
    }

    // MARK: - Bridge: shared-engine hosting

    func testHostingMovesThePlayerNodeOntoTheCaptureEngineAndBack() async throws {
        let capture = TapQAudioCaptureEngine()
        let playback = TapQAudioPlaybackEngine()
        XCTAssertNil(capture.hostedPlayback)
        XCTAssertTrue(playback.player.engine === playback.engine)

        var hostError: NSError?
        guard TapQAudioCaptureEngineHostPlaybackPlayer(
            capture, playback, 24_000, 1, &hostError
        ) else {
            throw XCTSkip(
                "no reachable audio graph on this host: "
                    + (hostError?.localizedDescription ?? "unknown"))
        }

        XCTAssertTrue(capture.hostedPlayback === playback)
        XCTAssertTrue(playback.player.engine === capture.engine,
                      "voice processing can only cancel output its own engine can see")

        var releaseError: NSError?
        XCTAssertTrue(TapQAudioCaptureEngineReleasePlaybackPlayer(capture, &releaseError))
        XCTAssertNil(releaseError)
        XCTAssertNil(capture.hostedPlayback)
        XCTAssertTrue(playback.player.engine === playback.engine,
                      "the player goes home to the engine that owns it")
    }

    func testStoppingTheCaptureEngineReleasesAHostedPlayer() async throws {
        let capture = TapQAudioCaptureEngine()
        let playback = TapQAudioPlaybackEngine()

        var hostError: NSError?
        guard TapQAudioCaptureEngineHostPlaybackPlayer(
            capture, playback, 24_000, 1, &hostError
        ) else {
            throw XCTSkip(
                "no reachable audio graph on this host: "
                    + (hostError?.localizedDescription ?? "unknown"))
        }

        var stopError: NSError?
        XCTAssertTrue(TapQAudioCaptureEngineStop(capture, &stopError))
        XCTAssertNil(capture.hostedPlayback)
        XCTAssertTrue(playback.player.engine === playback.engine)
    }

    func testReleasingWithNothingHostedSucceedsAndTouchesNothing() async {
        let capture = TapQAudioCaptureEngine()
        var error: NSError?
        XCTAssertTrue(TapQAudioCaptureEngineReleasePlaybackPlayer(capture, &error))
        XCTAssertNil(error)
        XCTAssertNil(capture.hostedPlayback)
    }

    func testAnUnusablePlaybackFormatIsReportedNotRaised() async {
        let capture = TapQAudioCaptureEngine()
        let playback = TapQAudioPlaybackEngine()
        var error: NSError?

        XCTAssertFalse(TapQAudioCaptureEngineHostPlaybackPlayer(
            capture, playback, 0, 0, &error))

        XCTAssertEqual(error?.userInfo[TapQAudioCaptureFailureStageKey] as? String,
                       "player_hosting")
        XCTAssertNil(capture.hostedPlayback)
        XCTAssertTrue(playback.player.engine === playback.engine,
                      "a rejected format leaves the player where it was")
    }
}
