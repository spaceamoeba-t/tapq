import XCTest
import TapQContracts
import TapQDetectionBaseline
@testable import TapQInteractionBaseline

/// Tier 3: the M2 wearer paths, where the IMU answers questions the microphone cannot —
/// who said that, and is the wearer still talking.
///
/// Both tests drive a real `WearerSpeechMonitor` with a synthetic jerk envelope, so the
/// speaking/quiet answers, the hangover, and the staleness horizon are all the shipping
/// detector's own. The stream's timestamps and the monotonic clock the consumers read are
/// the same clock, which is what makes "inside the attribution window" mean what it says.
@MainActor
final class WearerPathE2ETests: XCTestCase {
    /// One approval prompt answered three times over, by the same word from three different
    /// worlds: the wearer said it, somebody else said it, and nobody can tell.
    func testOnlyTheWearersYesApproves() async throws {
        let clock = StreamClock()
        let monitor = WearerSpeechMonitor(monotonicNow: { clock.now })
        let signal = MonitorSpeechSignal(monitor: monitor)
        let harness = DetectionPathHarness(voiceGate: { channel, sink in
            WearerGatedVoice(wrapping: channel, signal: signal,
                             monotonicNow: { clock.now }, diagnosticSink: sink)
        })
        var cursor = TraceGenerators.epoch

        // (a) The wearer speaks, stops, and the recognizer's match lands a few hundred
        // milliseconds later — the ordinary case, and the reason the window looks backwards.
        let approved = Task { await harness.interaction.resolve(Self.request) }
        let firstWindow = await harness.waitForWindow(1)
        XCTAssertTrue(firstWindow)

        cursor = stream(TraceGenerators.speechEnvelope(startingAt: cursor),
                        into: monitor, clock: clock)
        XCTAssertEqual(monitor.state, .speaking, "the envelope must read as wearer speech")
        cursor = stream(TraceGenerators.restingJitter(startingAt: cursor, duration: 1.0),
                        into: monitor, clock: clock)
        XCTAssertEqual(monitor.state, .quiet, "the utterance must be over when the match lands")
        XCTAssertTrue(signal.isSignalAvailable, "a quiet wearer is not an absent signal")
        harness.hear("yes")

        let allowed = await approved.value
        XCTAssertEqual(allowed, .allow)

        // (b) Nobody in the room is wearing the earbuds. The same transcript arrives with
        // the wearer's last speech well outside the attribution window.
        let deferred = Task { await harness.interaction.resolve(Self.request) }
        let secondWindow = await harness.waitForWindow(2)
        XCTAssertTrue(secondWindow)

        cursor = stream(TraceGenerators.restingJitter(startingAt: cursor, duration: 3.0),
                        into: monitor, clock: clock)
        harness.hear("yes")

        XCTAssertEqual(harness.diagnostics.events.filter { $0.name == "input.voice" }.count, 1,
                       "a bystander's yes reached the arbiter")
        let rejection = try XCTUnwrap(
            harness.diagnostics.events.last { $0.name == "command.rejected_nonwearer" },
            "the gate dropped the command without saying why"
        )
        XCTAssertEqual(rejection.fields["attribution_window_seconds"], "2.000")

        harness.timeouts.expire()
        let outcome = await deferred.value
        XCTAssertEqual(outcome, .ask, "an unattributed approval defers; it never allows")

        // (c) The stream stops — AirPods asleep, motion updates gone. Attribution may only
        // ever remove commands it is sure about, so an absent signal answers as it always did.
        let failedOpen = Task { await harness.interaction.resolve(Self.request) }
        let thirdWindow = await harness.waitForWindow(3)
        XCTAssertTrue(thirdWindow)

        clock.now += monitor.stalenessHorizon + Self.beyondStaleness
        XCTAssertFalse(signal.isSignalAvailable, "the stalled stream must read as unavailable")
        harness.hear("yes")

        let passedThrough = await failedOpen.value
        XCTAssertEqual(passedThrough, .allow, "a dead signal must fail open, not deny")
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.passed_signal_unavailable"
        })
        XCTAssertEqual(harness.inputs.openedWindows, 3, "one window per phase, no re-listens")
    }

    /// The agent is mid-sentence and the wearer starts talking over it: the response is cut
    /// off on the spot, and when the wearer stops, the turn commits a delay later.
    func testSpeechOnsetInterruptsPlaybackAndSilenceEndpointsTheTurn() async {
        let clock = StreamClock()
        let monitor = WearerSpeechMonitor(monotonicNow: { clock.now })
        let signal = MonitorSpeechSignal(monitor: monitor)
        let turn = TurnRecorder()
        let coordinator = WearerTurnCoordinator(
            signal: signal,
            endpoint: { turn.endpoint() },
            interruptPlayback: { turn.interrupt() },
            isResponsePlaying: { turn.isResponsePlaying },
            isUserTurnActive: { true },
            delaySleep: { await turn.sleep($0) }
        )
        coordinator.start()
        turn.beginResponse()
        var cursor = TraceGenerators.epoch

        cursor = stream(TraceGenerators.speechEnvelope(startingAt: cursor),
                        into: monitor, clock: clock)

        XCTAssertEqual(monitor.state, .speaking)
        XCTAssertEqual(turn.interruptions, 1, "speech onset over a response must barge in")
        XCTAssertFalse(turn.isResponsePlaying)
        XCTAssertEqual(turn.endpoints, 0, "barge-in is not an endpoint")

        cursor = stream(TraceGenerators.restingJitter(startingAt: cursor, duration: 1.0),
                        into: monitor, clock: clock)
        await settle()

        XCTAssertEqual(monitor.state, .quiet)
        XCTAssertEqual(turn.requestedDelays, [WearerTurnCoordinator.defaultEndpointDelay],
                       "the commit must wait exactly the configured endpoint delay")
        XCTAssertEqual(WearerTurnCoordinator.defaultEndpointDelay, 0.4)
        XCTAssertEqual(turn.endpoints, 1, "the silence must commit the turn exactly once")
        XCTAssertEqual(turn.interruptions, 1, "the response was already cut off")
    }

    // MARK: - Stream plumbing

    /// Feeds a trace to the monitor with the monotonic clock pinned to each sample's own
    /// timestamp, so freshness and the attribution window are measured in stream time
    /// rather than in wall-clock time this test does not control. Returns where the next
    /// contiguous trace starts — a gap wider than `maxSampleGapSeconds` would reset the
    /// detector instead of continuing the stream.
    @discardableResult
    private func stream(_ trace: [HeadMotionSample],
                        into monitor: WearerSpeechMonitor,
                        clock: StreamClock) -> TimeInterval {
        for sample in trace {
            clock.now = sample.timestamp
            monitor.ingest(sample)
        }
        return (trace.last?.timestamp ?? clock.now) + TraceGenerators.sampleInterval
    }

    /// Yields the main actor enough for the coordinator's endpoint-delay task to run.
    private func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }

    /// The monotonic clock the monitor and the wearer gate both read. Not `VirtualClock`:
    /// these consumers take a `TimeInterval` seam, not a `ContinuousClock.Instant` one.
    private final class StreamClock {
        var now: TimeInterval = TraceGenerators.epoch
    }

    /// The runtime side of turn control. `interrupt` flushes the audio exactly as the live
    /// closure does, so the endpoint half of the test runs against a response already cut
    /// off, and `sleep` records what the coordinator asked to wait instead of waiting.
    @MainActor
    private final class TurnRecorder {
        private(set) var isResponsePlaying = false
        private(set) var interruptions = 0
        private(set) var endpoints = 0
        private(set) var requestedDelays: [TimeInterval] = []

        func beginResponse() { isResponsePlaying = true }
        func interrupt() {
            interruptions += 1
            isResponsePlaying = false
        }
        func endpoint() { endpoints += 1 }
        func sleep(_ seconds: TimeInterval) async { requestedDelays.append(seconds) }
    }

    /// Comfortably past the horizon: the stream has stopped, not merely jittered.
    private static let beyondStaleness: TimeInterval = 0.1

    private static let request = ApprovalRequest(
        id: "r1", sessionID: "s1", toolName: "Bash",
        summary: "run the test suite", detail: "swift test"
    )
}
