import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class WearerTurnCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    /// A wearer-speech signal whose transitions and availability the test drives by hand.
    @MainActor
    private final class FakeSignal: WearerSpeechSignaling {
        private(set) var isWearerSpeaking = false
        var isSignalAvailable = true
        var onWearerSpeakingChange: (@MainActor (Bool) -> Void)?

        init(speaking: Bool = false, available: Bool = true) {
            isWearerSpeaking = speaking
            isSignalAvailable = available
        }

        func setSpeaking(_ speaking: Bool) {
            guard speaking != isWearerSpeaking else { return }
            isWearerSpeaking = speaking
            onWearerSpeakingChange?(speaking)
        }
    }

    /// Recording closure that counts invocations and tracks per-call details.
    @MainActor
    private final class CallRecorder {
        private(set) var endpointCount = 0
        private(set) var interruptCount = 0

        var endpoint: @MainActor () -> Void {
            { [weak self] in self?.endpointCount += 1 }
        }

        var interruptPlayback: @MainActor () -> Void {
            { [weak self] in self?.interruptCount += 1 }
        }
    }

    // MARK: - Factory

    private func makeCoordinator(
        signal: FakeSignal,
        recorder: CallRecorder,
        responsePlaying: @escaping @MainActor () -> Bool = { false },
        turnActive: @escaping @MainActor () -> Bool = { true },
        endpointDelay: TimeInterval = 0.01,
        delaySleep: @escaping @MainActor (TimeInterval) async -> Void = { _ in }
    ) -> WearerTurnCoordinator {
        WearerTurnCoordinator(
            signal: signal,
            endpoint: recorder.endpoint,
            interruptPlayback: recorder.interruptPlayback,
            isResponsePlaying: responsePlaying,
            isUserTurnActive: turnActive,
            endpointDelay: endpointDelay,
            delaySleep: delaySleep
        )
    }

    /// Yields the main actor enough for async timer tasks to settle.
    private func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }

    // MARK: - Endpointing basics

    func testEndpointFiresOnceAfterDelay() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(signal: signal, recorder: recorder)
        coordinator.start()

        // Onset: wearer starts speaking.
        signal.setSpeaking(true)
        // Offset: wearer stops speaking.
        signal.setSpeaking(false)
        await settle()

        XCTAssertEqual(recorder.endpointCount, 1, "endpoint should fire once after delay")
    }

    func testEndpointFiresOnlyOncePerTurn() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(signal: signal, recorder: recorder)
        coordinator.start()

        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()

        // A second onset/offset in the same turn should NOT fire again.
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()

        XCTAssertEqual(recorder.endpointCount, 1,
                       "endpoint fires only once per turn (per start())")
    }

    func testResumeWithinDelayCancelsEndpoint() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        var sleepContinuation: CheckedContinuation<Void, Never>?

        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            delaySleep: { _ in
                await withCheckedContinuation { continuation in
                    sleepContinuation = continuation
                }
            }
        )
        coordinator.start()

        signal.setSpeaking(true)
        signal.setSpeaking(false)
        // The sleep is suspended (timer running). Resume speaking.
        signal.setSpeaking(true)
        // Now let the sleep finish.
        sleepContinuation?.resume()
        await settle()

        XCTAssertEqual(recorder.endpointCount, 0,
                       "resuming speech before delay expires cancels the endpoint")
    }

    // MARK: - Warm-up guard

    func testNoEndpointWithoutPriorOnsetInTurn() async {
        let signal = FakeSignal(speaking: true)
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(signal: signal, recorder: recorder)
        coordinator.start()

        // Stop speaking without a prior startedSpeaking transition in this turn.
        // The signal was already speaking when start() was called, so no onset
        // transition fired.
        signal.setSpeaking(false)
        await settle()

        XCTAssertEqual(recorder.endpointCount, 0,
                       "no endpoint without a prior onset in-turn (warm-up guard)")
    }

    func testOnsetThenOffsetInTurnDoesEndpoint() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(signal: signal, recorder: recorder)
        coordinator.start()

        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()

        XCTAssertEqual(recorder.endpointCount, 1)
    }

    // MARK: - Signal unavailable

    func testNoEndpointWhenSignalUnavailable() async {
        let signal = FakeSignal(available: false)
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(signal: signal, recorder: recorder)
        coordinator.start()

        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()

        XCTAssertEqual(recorder.endpointCount, 0,
                       "coordinator ignores transitions when signal is unavailable")
    }

    func testNoEndpointWhenSignalBecomesUnavailableDuringDelay() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        var sleepContinuation: CheckedContinuation<Void, Never>?

        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            delaySleep: { _ in
                await withCheckedContinuation { continuation in
                    sleepContinuation = continuation
                }
            }
        )
        coordinator.start()

        signal.setSpeaking(true)
        signal.setSpeaking(false)
        // While the delay is in flight, the signal becomes unavailable.
        signal.isSignalAvailable = false
        sleepContinuation?.resume()
        await settle()

        XCTAssertEqual(recorder.endpointCount, 0,
                       "stale signal during delay prevents endpoint (fail open)")
    }

    // MARK: - Turn active guard

    func testNoEndpointWhenTurnNotActive() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            turnActive: { false }
        )
        coordinator.start()

        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()

        XCTAssertEqual(recorder.endpointCount, 0,
                       "no endpoint when user turn is not active")
    }

    func testNoEndpointWhenTurnResolvedDuringDelay() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        var turnActive = true
        var sleepContinuation: CheckedContinuation<Void, Never>?

        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            turnActive: { turnActive },
            delaySleep: { _ in
                await withCheckedContinuation { continuation in
                    sleepContinuation = continuation
                }
            }
        )
        coordinator.start()

        signal.setSpeaking(true)
        signal.setSpeaking(false)
        // Turn resolved by a match while delay is in flight.
        turnActive = false
        sleepContinuation?.resume()
        await settle()

        XCTAssertEqual(recorder.endpointCount, 0,
                       "no endpoint when the turn resolved during delay")
    }

    // MARK: - Barge-in

    func testBargeInFiresOncePerPlayingResponse() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        var responsePlaying = true

        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            responsePlaying: { responsePlaying }
        )
        coordinator.start()

        // Speech onset while response is playing -> barge-in.
        signal.setSpeaking(true)
        XCTAssertEqual(recorder.interruptCount, 1)

        // A second onset during the same response should NOT fire again.
        signal.setSpeaking(false)
        signal.setSpeaking(true)
        XCTAssertEqual(recorder.interruptCount, 1,
                       "barge-in fires once per response")
    }

    func testBargeInResetsForNewResponse() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        var responsePlaying = true

        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            responsePlaying: { responsePlaying }
        )
        coordinator.start()

        // First response: barge-in fires.
        signal.setSpeaking(true)
        XCTAssertEqual(recorder.interruptCount, 1)

        // Response ends.
        responsePlaying = false
        signal.setSpeaking(false)

        // New response: barge-in should fire again.
        responsePlaying = true
        signal.setSpeaking(true)
        XCTAssertEqual(recorder.interruptCount, 2)
    }

    func testBargeInDoesNotFireWhenIdle() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            responsePlaying: { false }
        )
        coordinator.start()

        signal.setSpeaking(true)
        XCTAssertEqual(recorder.interruptCount, 0,
                       "no barge-in when no response is playing")
    }

    // MARK: - Armed/disarmed

    func testNoCallsAfterStop() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        var responsePlaying = true

        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            responsePlaying: { responsePlaying }
        )
        coordinator.start()
        coordinator.stop()

        // Try endpoint path.
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()

        // Try barge-in path.
        signal.setSpeaking(true)

        XCTAssertEqual(recorder.endpointCount, 0,
                       "no endpoint after stop()")
        XCTAssertEqual(recorder.interruptCount, 0,
                       "no barge-in after stop()")
    }

    func testNoCallsBeforeStart() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        var responsePlaying = true

        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            responsePlaying: { responsePlaying }
        )
        // Note: start() NOT called.

        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()

        signal.setSpeaking(true)

        XCTAssertEqual(recorder.endpointCount, 0)
        XCTAssertEqual(recorder.interruptCount, 0)
    }

    func testRestartResetsState() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(signal: signal, recorder: recorder)

        coordinator.start()
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()
        XCTAssertEqual(recorder.endpointCount, 1)

        // Second start resets everything.
        coordinator.start()
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        await settle()
        XCTAssertEqual(recorder.endpointCount, 2,
                       "restart() allows endpoint to fire again for the new turn")
    }

    // MARK: - Wedged signal: coordinator never blocks existing paths

    /// Composing the coordinator with a full provider and ScriptedVoiceBackend: match-on-
    /// transcript and window timeout behave identically with the coordinator attached and
    /// the signal dead.
    func testWedgedSignalDoesNotBlockMatchResolution() async {
        let signal = FakeSignal()
        signal.isSignalAvailable = true
        // Wedge: signal reports quiet and never changes.

        let backend = ScriptedVoiceBackend()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: { text in
                text.lowercased().contains("yes") ? .yes : nil
            },
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            idleSleep: { _ in },
            diagnosticSink: NoOpTapQDiagnosticSink()
        )

        let recorder = CallRecorder()
        let coordinator = WearerTurnCoordinator(
            signal: signal,
            endpoint: { provider.endActiveTurn() },
            interruptPlayback: { provider.cancelActiveResponse() },
            isResponsePlaying: { provider.isResponseInFlight },
            isUserTurnActive: { provider.isUserTurnActiveForCoordination },
            delaySleep: { _ in }
        )
        coordinator.start()

        var received: [VoiceCommand] = []
        provider.start { received.append($0) }
        await settle()

        // Match-on-transcript resolves the window normally.
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes],
                       "match resolution works with coordinator attached and signal wedged")

        // The coordinator should not have fired anything.
        XCTAssertEqual(recorder.endpointCount, 0)
        XCTAssertEqual(recorder.interruptCount, 0)
    }

    // MARK: - End-to-end shaped test: scripted pipe backend + coordinator

    /// Simulates the OpenAI-shaped flow from the findings: wearer speaks -> endpoint
    /// commits -> post-commit transcript -> command matched.
    func testEndToEndEndpointingFlow() async {
        let signal = FakeSignal()
        let backend = ScriptedVoiceBackend()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: { text in
                text.lowercased().contains("yes") ? .yes : nil
            },
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            idleSleep: { _ in },
            diagnosticSink: NoOpTapQDiagnosticSink()
        )

        let coordinator = WearerTurnCoordinator(
            signal: signal,
            endpoint: { provider.endActiveTurn() },
            interruptPlayback: { provider.cancelActiveResponse() },
            isResponsePlaying: { provider.isResponseInFlight },
            isUserTurnActive: { provider.isUserTurnActiveForCoordination },
            delaySleep: { _ in }
        )
        coordinator.start()

        var received: [VoiceCommand] = []
        provider.start { received.append($0) }
        await settle()

        XCTAssertTrue(provider.isUserTurnActiveForCoordination)

        // Wearer starts speaking.
        signal.setSpeaking(true)
        // Wearer stops speaking -> endpoint fires after delay (instant in test).
        signal.setSpeaking(false)
        await settle()

        // The endpoint committed the turn.
        XCTAssertFalse(provider.isUserTurnActiveForCoordination,
                       "endActiveTurn was called by the endpoint")
        XCTAssertTrue(backend.calls.contains(.endUserTurn))

        // Post-commit transcript arrives (the OpenAI path: transcripts exist only after
        // commit). The handler is still armed, so a match resolves the window.
        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes],
                       "post-commit transcript resolves the window")
    }

    /// Simulates barge-in during response audio: onset -> flush + cancel -> next turn
    /// resolves by transcript.
    func testEndToEndBargeInFlow() async {
        let signal = FakeSignal()
        let backend = ScriptedVoiceBackend()
        let fakePlayback = FakePlaybackForCoordinator()

        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: { text in
                text.lowercased().contains("yes") ? .yes : nil
            },
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: fakePlayback,
            idleSleep: { _ in },
            diagnosticSink: NoOpTapQDiagnosticSink()
        )

        var speechStopAllCount = 0
        let coordinator = WearerTurnCoordinator(
            signal: signal,
            endpoint: { provider.endActiveTurn() },
            interruptPlayback: {
                fakePlayback.stopAndFlush()
                provider.cancelActiveResponse()
                speechStopAllCount += 1
            },
            isResponsePlaying: { fakePlayback.isPlaying },
            isUserTurnActive: { provider.isUserTurnActiveForCoordination },
            delaySleep: { _ in }
        )
        coordinator.start()

        var received: [VoiceCommand] = []
        provider.start { received.append($0) }
        await settle()

        // Backend starts sending response audio.
        let chunk = VoiceAudioChunk(data: Data([1, 2, 3, 4]),
                                     format: .pcm16Mono24k, timestamp: 1.0)
        backend.emit(.audio(chunk))
        XCTAssertTrue(fakePlayback.isPlaying)
        XCTAssertTrue(provider.isResponseInFlight)

        // Wearer starts speaking during response -> barge-in.
        signal.setSpeaking(true)
        XCTAssertEqual(speechStopAllCount, 1, "speech.stopAll() called on barge-in")
        XCTAssertTrue(backend.calls.contains(.cancelResponse),
                      "cancelActiveResponse sends cancelResponse to backend")
        XCTAssertFalse(fakePlayback.isPlaying,
                       "playback flushed on barge-in")
    }

    // MARK: - Default endpoint delay

    func testDefaultEndpointDelayIs04Seconds() {
        XCTAssertEqual(WearerTurnCoordinator.defaultEndpointDelay, 0.4,
                       "the provisional endpoint delay constant is 0.4 s")
    }

    // MARK: - Speech.stopAll() documented as deliberately blunt

    func testBargeInCallsInterruptPlaybackClosure() async {
        let signal = FakeSignal()
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(
            signal: signal,
            recorder: recorder,
            responsePlaying: { true }
        )
        coordinator.start()

        signal.setSpeaking(true)
        XCTAssertEqual(recorder.interruptCount, 1,
                       "interruptPlayback closure is called on barge-in (speech.stopAll() is " +
                       "the documented blunt implementation)")
    }

    // MARK: - ScriptedVoiceBackend (shared with provider tests, duplicated for isolation)

    /// Minimal scripted backend for end-to-end tests.
    @MainActor
    private final class ScriptedVoiceBackend: VoiceBackend {
        enum Call: Equatable {
            case open, close, beginUserTurn, endUserTurn
            case sendAudio(Int), requestResponse(String), cancelResponse
        }

        let capabilities: VoiceBackendCapabilities
        private(set) var calls: [Call] = []
        private(set) var handlers: [(@MainActor (VoiceBackendEvent) -> Void)] = []
        private(set) var isOpen = false
        private(set) var isTurnActive = false

        init(capabilities: VoiceBackendCapabilities = .transcriptOnly) {
            self.capabilities = capabilities
        }

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            calls.append(.open)
            isOpen = true
            handlers.append(onEvent)
        }

        func close() {
            calls.append(.close)
            isOpen = false
            isTurnActive = false
        }

        func beginUserTurn() {
            calls.append(.beginUserTurn)
            isTurnActive = true
        }

        func endUserTurn() {
            calls.append(.endUserTurn)
            isTurnActive = false
        }

        func sendAudio(_ chunk: VoiceAudioChunk) {
            calls.append(.sendAudio(chunk.data.count))
        }

        func requestResponse(text: String) {
            calls.append(.requestResponse(text))
        }

        func cancelResponse() {
            calls.append(.cancelResponse)
        }

        func emit(_ event: VoiceBackendEvent, toHandler index: Int? = nil) {
            guard !handlers.isEmpty else { return }
            handlers[index ?? handlers.count - 1](event)
        }
    }

    /// Minimal fake playback for end-to-end tests.
    @MainActor
    private final class FakePlaybackForCoordinator: VoiceResponseAudioPlaying {
        private(set) var isPlaying = false
        var onPlayingChange: (@MainActor (Bool) -> Void)?

        func enqueue(_ chunk: VoiceAudioChunk) {
            if !isPlaying {
                isPlaying = true
                onPlayingChange?(true)
            }
        }

        func finishStream() {}

        func stopAndFlush() {
            guard isPlaying else { return }
            isPlaying = false
            onPlayingChange?(false)
        }
    }

}
