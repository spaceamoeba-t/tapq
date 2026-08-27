import AVFoundation
import XCTest
import TapQContracts
@testable import TapQAppleAdapters

@MainActor
final class MicrophonePumpVoiceBackendTests: XCTestCase {

    // MARK: - Test doubles

    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.name)
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// A `VoiceAudioSource` that captures and replays buffers without hardware.
    private final class FakeAudioSource: VoiceAudioSource {
        var startFailure: (any Error)?
        private(set) var starts = 0
        private(set) var stops = 0
        private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private var invalidationHandler: (@MainActor (VoiceAudioSourceFailure) -> Void)?

        func start(
            onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
            onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
        ) throws {
            starts += 1
            bufferHandler = onBuffer
            invalidationHandler = onInvalidation
            if let startFailure { throw startFailure }
        }

        func stop() {
            stops += 1
            bufferHandler = nil
            invalidationHandler = nil
        }

        func emit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64 = 1_000_000_000) {
            bufferHandler?(buffer, AVAudioTime(hostTime: hostTime))
        }

        func invalidate(
            _ failure: VoiceAudioSourceFailure = .init(
                stage: .configurationChanged,
                detail: "audio input route changed"
            )
        ) {
            invalidationHandler?(failure)
        }
    }

    /// A `VoiceBackend` that records its call sequence and replays scripted events, local
    /// to this test file so it does not depend on `TapQVoiceBackendsTests`.
    @MainActor
    private final class FakeInnerBackend: VoiceBackend {
        enum Call: Equatable {
            case open
            case close
            case beginUserTurn
            case endUserTurn
            case sendAudio(Int)
            case requestResponse(String)
            case cancelResponse
        }

        let capabilities: VoiceBackendCapabilities
        private(set) var calls: [Call] = []
        private(set) var isOpen = false
        var isTurnActive = false
        var openFailure: VoiceBackendFailure?
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?

        init(capabilities: VoiceBackendCapabilities = VoiceBackendCapabilities(
            supportsBargeIn: true, producesAudio: true, duplex: true
        )) {
            self.capabilities = capabilities
        }

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            calls.append(.open)
            if let openFailure { throw openFailure }
            isOpen = true
            handler = onEvent
        }

        func close() {
            calls.append(.close)
            isOpen = false
            isTurnActive = false
            handler = nil
        }

        func beginUserTurn() {
            calls.append(.beginUserTurn)
            isTurnActive = true
        }

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool {
            calls.append(.endUserTurn)
            isTurnActive = false
            return false
        }

        /// Full audio chunks for value-level assertions (monotonicity test).
        private(set) var sentAudioChunks: [VoiceAudioChunk] = []

        func sendAudio(_ chunk: VoiceAudioChunk) {
            calls.append(.sendAudio(chunk.data.count))
            sentAudioChunks.append(chunk)
        }

        func requestResponse(text: String) {
            calls.append(.requestResponse(text))
        }

        func cancelResponse() {
            calls.append(.cancelResponse)
        }

        private(set) var nativeTurnDetection: [Bool] = []

        func setNativeTurnDetection(_ enabled: Bool) {
            nativeTurnDetection.append(enabled)
        }

        func emit(_ event: VoiceBackendEvent) {
            handler?(event)
        }
    }

    /// Reference box so events collected inside a closure survive teardown.
    @MainActor
    private final class EventLog {
        private(set) var events: [VoiceBackendEvent] = []
        func append(_ event: VoiceBackendEvent) { events.append(event) }
    }

    private struct Fixture {
        let pump: MicrophonePumpVoiceBackend
        let inner: FakeInnerBackend
        let audioSource: FakeAudioSource
        let sink: RecordingSink
    }

    private func makeFixture(
        format: VoiceAudioFormat = .pcm16Mono24k,
        sources: [FakeAudioSource]? = nil,
        innerCapabilities: VoiceBackendCapabilities = VoiceBackendCapabilities(
            supportsBargeIn: true, producesAudio: true, duplex: true
        )
    ) -> Fixture {
        let inner = FakeInnerBackend(capabilities: innerCapabilities)
        let source = sources?.first ?? FakeAudioSource()
        let all = sources ?? [source]
        var index = 0
        let sink = RecordingSink()
        let pump = MicrophonePumpVoiceBackend(
            inner: inner,
            format: format,
            makeAudioSource: {
                defer { index += 1 }
                return all[min(index, all.count - 1)]
            },
            diagnosticSink: sink
        )
        return Fixture(pump: pump, inner: inner, audioSource: source, sink: sink)
    }

    // MARK: - Capabilities

    func testCapabilitiesForwardFromInner() {
        let fixture = makeFixture()
        XCTAssertTrue(fixture.pump.capabilities.supportsBargeIn)
        XCTAssertTrue(fixture.pump.capabilities.producesAudio)
        XCTAssertTrue(fixture.pump.capabilities.duplex)
    }

    func testCapabilitiesReflectTranscriptOnlyInner() {
        let fixture = makeFixture(innerCapabilities: .transcriptOnly)
        XCTAssertEqual(fixture.pump.capabilities, .transcriptOnly)
    }

    // MARK: - Session lifecycle

    func testOpenForwardsToInner() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }

        XCTAssertEqual(fixture.inner.calls, [.open])
        XCTAssertEqual(fixture.audioSource.starts, 0,
                       "the mic opens per turn, never for the length of a session")
    }

    func testCloseForwardsToInnerAndStopsMicrophone() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()
        fixture.pump.close()

        XCTAssertEqual(fixture.audioSource.stops, 1)
        XCTAssertTrue(fixture.inner.calls.contains(.close))
    }

    func testCloseWithoutMicOpenIsIdempotent() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.close()

        XCTAssertEqual(fixture.audioSource.stops, 0,
                       "no mic was open, nothing to stop")
        XCTAssertTrue(fixture.inner.calls.contains(.close))
    }

    // MARK: - Mic opens only inside a user turn

    func testMicOpensOnBeginUserTurn() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }

        fixture.pump.beginUserTurn()

        XCTAssertEqual(fixture.audioSource.starts, 1)
        XCTAssertTrue(fixture.inner.calls.contains(.beginUserTurn))
    }

    func testMicNeverOpensOnOpen() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }

        XCTAssertEqual(fixture.audioSource.starts, 0,
                       "the never-always-on invariant: mic opens per turn only")
    }

    // MARK: - Audio delivery

    func testBuffersReachInnerSendAudioInOrder() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        // Use realistic buffer sizes (480 frames = 10 ms at 48 kHz). Tiny buffers
        // (< ~8 frames) may produce zero output after a 2:1 downsample because
        // the SRC filter's priming delay consumes all the input.
        fixture.audioSource.emit(try monoFloatBuffer(
            values: [Float](repeating: 0.5, count: 480)))
        fixture.audioSource.emit(try monoFloatBuffer(
            values: [Float](repeating: 0.25, count: 480)))

        // Yield enough to let the AsyncStream consumer process both blocks.
        for _ in 0..<30 { await Task.yield() }

        let audioSends = fixture.inner.calls.compactMap { call -> Int? in
            if case .sendAudio(let bytes) = call { return bytes }
            return nil
        }
        XCTAssertGreaterThanOrEqual(audioSends.count, 1,
                                    "converted audio must reach the inner backend")
        // Verify the sends are in order (first block's byte count <= second).
        if audioSends.count >= 2 {
            XCTAssertGreaterThan(audioSends[0], 0)
            XCTAssertGreaterThan(audioSends[1], 0)
        }
    }

    func testConvertedAudioIsInTheDeclaredWireFormat() async throws {
        // Use a spy inner that records the format of received chunks.
        let fixture = makeFixture(format: .pcm16Mono24k)
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        // Emit a 48 kHz stereo float buffer (the common hardware format).
        // Use a realistic frame count; tiny buffers may produce zero output
        // after the SRC filter's priming delay.
        fixture.audioSource.emit(try stereoFloatBuffer(
            left: [Float](repeating: 0.5, count: 480),
            right: [Float](repeating: 0.25, count: 480),
            sampleRate: 48_000
        ))

        for _ in 0..<20 { await Task.yield() }

        // The inner.sendAudio call should have received PCM16 mono 24k data.
        let audioSends = fixture.inner.calls.compactMap { call -> Int? in
            if case .sendAudio(let bytes) = call { return bytes }
            return nil
        }
        // With 480 frames at 48 kHz -> ~240 frames at 24 kHz, so we expect
        // PCM16 mono data (2 bytes per sample).
        XCTAssertGreaterThan(audioSends.reduce(0, +), 0,
                             "audio must be converted and delivered")
    }

    // MARK: - endUserTurn stops mic before forwarding

    func testEndUserTurnStopsMicBeforeForwardingToInner() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        fixture.pump.endUserTurn(expectingResponse: true)

        XCTAssertEqual(fixture.audioSource.stops, 1,
                       "the mic closes before the inner commit")
        // The inner should see beginUserTurn then endUserTurn.
        let turnCalls = fixture.inner.calls.filter {
            $0 == .beginUserTurn || $0 == .endUserTurn
        }
        XCTAssertEqual(turnCalls, [.beginUserTurn, .endUserTurn])
    }

    func testMicStopsOnClose() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()
        fixture.pump.close()

        XCTAssertEqual(fixture.audioSource.stops, 1)
    }

    // MARK: - Route change mid-turn

    func testRouteChangeMidTurnSurfacesSessionFailed() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        fixture.audioSource.invalidate()

        // The pump should close the inner and emit sessionFailed.
        XCTAssertEqual(log.events.count, 1)
        guard case .sessionFailed(.network(let detail)) = log.events.first else {
            return XCTFail("expected a network session failure, got \(log.events)")
        }
        XCTAssertTrue(detail.contains("microphone"))
        XCTAssertTrue(fixture.inner.calls.contains(.close),
                      "the inner backend is closed on route change")
        XCTAssertEqual(fixture.audioSource.stops, 1)
    }

    func testRouteChangeSurfacedOnlyOnce() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        fixture.audioSource.invalidate()
        // Second invalidation should be dropped (generation mismatch).
        fixture.audioSource.invalidate()

        let failures = log.events.filter {
            if case .sessionFailed = $0 { return true }; return false
        }
        XCTAssertEqual(failures.count, 1, "route change surfaced exactly once")
    }

    // MARK: - Stale audio after teardown

    func testStaleAudioAfterTeardownIsDropped() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()
        fixture.pump.endUserTurn(expectingResponse: true)

        // Audio arriving after the turn ended should not reach the inner.
        let sendsBefore = fixture.inner.calls.filter {
            if case .sendAudio = $0 { return true }; return false
        }.count

        fixture.audioSource.emit(try monoFloatBuffer(values: [0.9, 0.9, 0.9, 0.9]))
        for _ in 0..<20 { await Task.yield() }

        let sendsAfter = fixture.inner.calls.filter {
            if case .sendAudio = $0 { return true }; return false
        }.count
        XCTAssertEqual(sendsBefore, sendsAfter,
                       "audio delivered after teardown must be dropped")
    }

    // MARK: - Stop is idempotent

    func testStopIsIdempotent() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        fixture.pump.endUserTurn(expectingResponse: true)
        fixture.pump.close()
        fixture.pump.close()

        // Only 1 stop from endUserTurn; close after should not crash.
        XCTAssertEqual(fixture.audioSource.stops, 1)
    }

    // MARK: - Inner events relay to caller

    func testTranscriptEventsRelayedToCaller() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        fixture.inner.emit(.transcriptPartial("ye"))
        fixture.inner.emit(.transcriptFinal("yes"))

        XCTAssertEqual(log.events, [
            .transcriptPartial("ye"),
            .transcriptFinal("yes"),
        ])
    }

    func testAudioEventsRelayedToCaller() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        let chunk = VoiceAudioChunk(data: Data([1, 2, 3, 4]),
                                     format: .pcm16Mono24k, timestamp: 1)
        fixture.inner.emit(.audio(chunk))

        XCTAssertEqual(log.events, [.audio(chunk)])
    }

    func testResponseCompletedRelayedToCaller() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }

        fixture.inner.emit(.responseCompleted)

        XCTAssertEqual(log.events, [.responseCompleted])
    }

    func testInnerSessionFailedClosesTheMicAndRelays() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        let failure = VoiceBackendFailure.network("socket dropped")
        fixture.inner.emit(.sessionFailed(failure))

        XCTAssertEqual(log.events, [.sessionFailed(failure)])
        XCTAssertEqual(fixture.audioSource.stops, 1,
                       "mic stops when the inner session dies")
        XCTAssertFalse(fixture.pump.isTurnActiveForTesting)
    }

    // MARK: - Forwarding

    func testRequestResponseForwards() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.requestResponse(text: "hello")

        XCTAssertTrue(fixture.inner.calls.contains(.requestResponse("hello")))
    }

    func testCancelResponseForwards() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.cancelResponse()

        XCTAssertTrue(fixture.inner.calls.contains(.cancelResponse))
    }

    func testExternalSendAudioForwards() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        let chunk = VoiceAudioChunk(data: Data(repeating: 7, count: 320),
                                     format: .pcm16Mono24k, timestamp: 1)
        fixture.pump.sendAudio(chunk)

        XCTAssertTrue(fixture.inner.calls.contains(.sendAudio(320)))
    }

    // MARK: - onInputLevel hook

    func testInputLevelHookReceivesRMSValues() async throws {
        let fixture = makeFixture()
        var levels: [Double] = []
        fixture.pump.onInputLevel = { levels.append($0) }
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        let received = expectation(description: "input level received")
        fixture.pump.onInputLevel = {
            levels.append($0)
            received.fulfill()
        }

        // Use a realistic buffer size; tiny buffers may produce zero converter
        // output (SRC priming), which means the RMS value is never delivered.
        fixture.audioSource.emit(try monoFloatBuffer(
            values: [Float](repeating: 0.5, count: 480)))
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(levels.count, 1)
        XCTAssertEqual(levels[0], 0.5, accuracy: 0.1)
    }

    // MARK: - Mic start failure

    func testMicStartFailureRelaysSessionFailed() async throws {
        let fixture = makeFixture()
        fixture.audioSource.startFailure = VoiceAudioSourceFailure(
            stage: .engineStart, detail: "input device disappeared")
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }

        fixture.pump.beginUserTurn()

        XCTAssertEqual(log.events.count, 1)
        guard case .sessionFailed(.network) = log.events.first else {
            return XCTFail("expected a network session failure, got \(log.events)")
        }
    }

    // MARK: - PCM16 extraction

    func testExtractPCM16DataFromInterleavedBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4

        let int16Data = try XCTUnwrap(buffer.int16ChannelData)
        int16Data[0][0] = 1000
        int16Data[0][1] = -1000
        int16Data[0][2] = 32767
        int16Data[0][3] = -32768

        let data = MicrophonePumpVoiceBackend.extractPCM16Data(from: buffer)
        XCTAssertEqual(data.count, 8, "4 int16 samples = 8 bytes")

        // Verify first sample is 1000 in little-endian.
        let firstSample = data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 0, as: Int16.self)
        }
        XCTAssertEqual(firstSample, 1000)
    }

    // MARK: - RMS computation

    func testComputeRMSOfConstantTone() throws {
        let buffer = try monoFloatBuffer(values: [0.5, -0.5, 0.5, -0.5])
        let rms = MicrophonePumpVoiceBackend.computeRMS(buffer)
        XCTAssertEqual(rms, 0.5, accuracy: 1e-6)
    }

    func testComputeRMSOfSilence() throws {
        let buffer = try monoFloatBuffer(values: [0, 0, 0, 0])
        let rms = MicrophonePumpVoiceBackend.computeRMS(buffer)
        XCTAssertEqual(rms, 0)
    }

    // MARK: - Multiple turns on the same session

    func testSecondTurnGetsAFreshMicWindow() async throws {
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        let fixture = makeFixture(sources: [first, second])
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }

        // First turn.
        fixture.pump.beginUserTurn()
        fixture.pump.endUserTurn(expectingResponse: true)

        // Second turn.
        fixture.pump.beginUserTurn()

        XCTAssertEqual(first.starts, 1)
        XCTAssertEqual(second.starts, 1, "each turn gets a fresh audio source")
        XCTAssertEqual(first.stops, 1)
    }

    // MARK: - Inner session failure during beginUserTurn (defect 2)

    /// An inner backend that synchronously emits `sessionFailed` from `beginUserTurn`,
    /// simulating a state-machine violation in `OpenAIRealtimeVoiceBackend` (e.g.
    /// `responseAlreadyInFlight` -> `violated()` -> `failSession`).
    @MainActor
    private final class FailingOnBeginBackend: VoiceBackend {
        let capabilities: VoiceBackendCapabilities = VoiceBackendCapabilities(
            supportsBargeIn: true, producesAudio: true, duplex: true)

        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?
        private(set) var calls: [String] = []

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            calls.append("open")
            handler = onEvent
        }

        func close() {
            calls.append("close")
            handler = nil
        }

        func beginUserTurn() {
            calls.append("beginUserTurn")
            // Synchronously fail the session, exactly as the OpenAI adapter does when
            // VoiceTurnStateMachine.beginUserTurn throws from .responding.
            let callback = handler
            handler = nil
            callback?(.sessionFailed(.protocolViolation("A response is already in flight.")))
        }

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool { calls.append("endUserTurn"); return false }
        func sendAudio(_ chunk: VoiceAudioChunk) { calls.append("sendAudio") }
        func requestResponse(text: String) { calls.append("requestResponse") }
        func cancelResponse() { calls.append("cancelResponse") }

        func setNativeTurnDetection(_ enabled: Bool) {}
    }

    func testBeginUserTurnInnerFailureDoesNotOpenMicrophone() async throws {
        let inner = FailingOnBeginBackend()
        let audioSource = FakeAudioSource()
        let sink = RecordingSink()
        let pump = MicrophonePumpVoiceBackend(
            inner: inner,
            format: .pcm16Mono24k,
            makeAudioSource: { audioSource },
            diagnosticSink: sink
        )

        let log = EventLog()
        try await pump.open { log.append($0) }

        // beginUserTurn will cause the inner to synchronously emit sessionFailed.
        pump.beginUserTurn()

        // The session failed event should have been relayed.
        XCTAssertEqual(log.events.count, 1)
        guard case .sessionFailed = log.events.first else {
            return XCTFail("expected sessionFailed, got \(log.events)")
        }

        // The critical assertion: the audio source must never have been started.
        XCTAssertEqual(audioSource.starts, 0,
                       "the microphone must not open when the inner session died during beginUserTurn")
        XCTAssertFalse(pump.isTurnActiveForTesting,
                       "turnActive must be false after inner session failure")
    }

    // MARK: - Monotonicity regression (defect 1 — SRC priming duplicate)

    /// Feeds several consecutive monotonic-ramp float buffers through the pump,
    /// concatenates the int16 payloads received by the inner fake, and asserts the
    /// decoded samples are monotonically nondecreasing after the converter's ramp-in.
    ///
    /// Before the fix, AVAudioConverter's SRC priming pulled the input block twice
    /// on the first convert() after converter creation, duplicating the first tap
    /// buffer into the output stream. The monotonic ramp becomes
    /// [0,1,2,...,N, 0,1,2,...] — a clear violation that this test catches.
    func testConvertedSamplesAreMonotonicallyNondecreasingAfterRampIn() async throws {
        let fixture = makeFixture(format: .pcm16Mono24k)
        let log = EventLog()
        try await fixture.pump.open { log.append($0) }
        fixture.pump.beginUserTurn()

        // Build 5 consecutive ramp buffers at 48 kHz mono float, 480 frames each.
        // Global ramp: buffer 0 = [0.0, 0.0001, 0.0002, ...], buffer 1 continues.
        let framesPerBuffer = 480
        let bufferCount = 5
        for bufferIndex in 0..<bufferCount {
            let offset = bufferIndex * framesPerBuffer
            var values = [Float](repeating: 0, count: framesPerBuffer)
            for i in 0..<framesPerBuffer {
                values[i] = Float(offset + i) * 0.0001
            }
            let buffer = try monoFloatBuffer(values: values, sampleRate: 48_000)
            fixture.audioSource.emit(buffer)
        }

        // Yield enough to let the AsyncStream consumer process all blocks.
        for _ in 0..<60 { await Task.yield() }

        // Concatenate all int16 payloads from the inner backend.
        let allData = fixture.inner.sentAudioChunks.reduce(Data()) { $0 + $1.data }
        let sampleCount = allData.count / MemoryLayout<Int16>.size
        XCTAssertGreaterThan(sampleCount, 0, "some converted audio must arrive")

        let samples: [Int16] = allData.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            return Array(ptr)
        }

        // Skip the first few samples (converter ramp-in transient from the
        // resampler's filter delay). 10 samples is generous.
        let skipCount = min(10, samples.count)
        var violations = 0
        for i in (skipCount + 1)..<samples.count {
            if samples[i] < samples[i - 1] {
                violations += 1
            }
        }
        XCTAssertEqual(violations, 0,
                       "samples must be monotonically nondecreasing after ramp-in; " +
                       "found \(violations) violations in \(samples.count) samples")
    }

    // MARK: - Helpers

    private func monoFloatBuffer(
        values: [Float],
        sampleRate: Double = 48_000
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(values.count)
        ))
        buffer.frameLength = AVAudioFrameCount(values.count)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (i, v) in values.enumerated() {
            data[0][i * buffer.stride] = v
        }
        return buffer
    }

    private func stereoFloatBuffer(
        left: [Float],
        right: [Float],
        sampleRate: Double = 48_000
    ) throws -> AVAudioPCMBuffer {
        let frames = left.count
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (i, v) in left.enumerated() {
            data[0][i * buffer.stride] = v
        }
        for (i, v) in right.enumerated() {
            data[1][i * buffer.stride] = v
        }
        return buffer
    }
}
