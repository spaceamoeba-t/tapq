import Foundation
import TapQBrokerRuntime
import TapQContracts
import TapQDetectionBaseline
@testable import TapQInteractionBaseline

/// The real, fully composed detection-to-decision stack, driven by synthetic IMU traces.
///
/// Composition is deliberately the production one: a real `MotionGesturePipeline` feeds a
/// forwarding-only adapter, which feeds a real `InputArbiter`/`SelectionArbiter`, which
/// feeds a real `InteractionController`/`SelectionController`. Only the edges are
/// substituted — the motion stream (generated traces), the microphone (transcript strings
/// through the real `VoiceCommandMatcher`), the speech engine, and the two clocks.
///
/// What that buys: a change that breaks the wiring between any two of those layers, or a
/// config default that drifts far enough to stop detecting a plainly-shaped gesture, fails
/// here. What it does not buy: any claim about real-world accuracy. See `TraceGenerators`.
@MainActor
final class DetectionPathHarness {
    /// How long the stream stays still between fed traces. Longer than every pair window
    /// and debounce in the pipeline (max 1.6 s), so consecutive traces cannot pair with
    /// each other and each one starts from a rested detector.
    static let idleGap: TimeInterval = 2.0

    let clock = VirtualClock()
    let speech = RecordingSpeech()
    let diagnostics = RecordingSink()
    let timeouts = ManualTimeout()
    let inputs: PipelineInputAdapter
    let voice = TranscriptVoiceChannel()
    let inputArbiter: InputArbiter
    let selectionArbiter: SelectionArbiter
    let interaction: InteractionController
    let selection: SelectionController

    /// The stream clock: where the next fed sample lands.
    private var cursor = TraceGenerators.epoch

    init(pipeline: MotionGesturePipeline = MotionGesturePipeline()) {
        let inputs = PipelineInputAdapter(pipeline: pipeline)
        self.inputs = inputs
        let timeouts = self.timeouts
        let sleep: @MainActor (TimeInterval) async -> Void = { await timeouts.sleep($0) }
        inputArbiter = InputArbiter(
            gestures: inputs, voice: voice, taps: inputs,
            diagnosticSink: diagnostics, timeoutSleep: sleep
        )
        selectionArbiter = SelectionArbiter(
            voice: voice, tilts: inputs, swipes: inputs, taps: inputs, gestures: inputs,
            diagnosticSink: diagnostics, timeoutSleep: sleep
        )
        interaction = InteractionController(
            speech: speech, arbiter: inputArbiter, diagnosticSink: diagnostics
        )
        selection = SelectionController(
            speech: speech, arbiter: selectionArbiter, diagnosticSink: diagnostics
        )
        let clock = self.clock
        interaction.now = { clock.now }
        selection.now = { clock.now }
    }

    /// Streams one trace into the pipeline at the current stream position, then keeps the
    /// stream running through `idleGap` seconds of stillness.
    func feed(_ trace: [HeadMotionSample]) {
        let rebased = TraceGenerators.shift(trace, to: cursor)
        for sample in rebased { inputs.ingest(sample) }
        cursor = (rebased.last?.timestamp ?? cursor) + TraceGenerators.sampleInterval
        for sample in TraceGenerators.quiet(startingAt: cursor, duration: Self.idleGap) {
            inputs.ingest(sample)
        }
        cursor += Self.idleGap
    }

    /// Delivers a recognizer transcript to the open window. The grammar under test is the
    /// real `VoiceCommandMatcher`, so an unmatched transcript is silently dropped exactly
    /// as it would be on device.
    func hear(_ transcript: String) {
        voice.hear(transcript)
    }

    /// Waits until the arbiter has opened its `index`-th input window (1-based), which is
    /// the point at which a fed trace can reach the decision layer. Polling rather than an
    /// expectation: the window opens on a later main-actor turn, and the house rule is no
    /// `XCTestExpectation` for actor hops.
    @discardableResult
    func waitForWindow(_ index: Int, attempts: Int = 2_000) async -> Bool {
        for _ in 0..<attempts {
            if inputs.openedWindows >= index { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return inputs.openedWindows >= index
    }
}

/// Test stand-in for `ContinuousClock`: time moves only when a test says so.
@MainActor
final class VirtualClock {
    private(set) var now: ContinuousClock.Instant = .now
    func advance(by seconds: TimeInterval) { now = now.advanced(by: .seconds(seconds)) }
}

/// The `InputArbiter`/`SelectionArbiter` timeout seam under test control: the window's
/// requested duration is recorded, and the sleep ends either when a test expires the
/// window or when the arbiter cancels the timer because an input resolved it first.
@MainActor
final class ManualTimeout {
    private(set) var requested: [TimeInterval] = []
    private var expired = false

    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        while !Task.isCancelled {
            if expired {
                expired = false
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Fires the timeout path for the window currently waiting.
    func expire() { expired = true }
}

/// Forwards `MotionGesturePipeline` detections to the arbiters, and nothing else.
///
/// This is the one piece the production stack builds differently (there, CoreMotion feeds
/// the pipeline inside `HeadGestureDetector`). It must stay a pass-through: no filtering,
/// no debounce, no interpretation — every one of those decisions belongs to the pipeline
/// or the arbiter, which is what this suite exists to exercise.
@MainActor
final class PipelineInputAdapter: HeadGestureProviding, TapCommandProviding,
                                  TiltCommandProviding, VolumeSwipeProviding {
    var pipeline: MotionGesturePipeline

    private var onGesture: (@MainActor (HeadGesture) -> Void)?
    private var onTap: (@MainActor (TapCommand) -> Void)?
    private var onTilt: (@MainActor (TiltCommand) -> Void)?
    private var onSwipe: (@MainActor (VolumeSwipeCommand) -> Void)?
    private var isOpen = false

    /// How many input windows have been opened on this adapter. An arbiter opens several
    /// channels per window, so this counts the window, not the channel.
    private(set) var openedWindows = 0

    init(pipeline: MotionGesturePipeline) {
        self.pipeline = pipeline
    }

    func start(onGesture: @escaping @MainActor (HeadGesture) -> Void) {
        openWindow()
        self.onGesture = onGesture
    }

    func start(onTap: @escaping @MainActor (TapCommand) -> Void) {
        openWindow()
        self.onTap = onTap
    }

    func start(onTilt: @escaping @MainActor (TiltCommand) -> Void) {
        openWindow()
        self.onTilt = onTilt
    }

    func start(onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void) {
        openWindow()
        self.onSwipe = onSwipe
    }

    func stop() {
        isOpen = false
        onGesture = nil
        onTap = nil
        onTilt = nil
        onSwipe = nil
    }

    /// Ingests one sample and hands every resulting detection straight to whichever
    /// channels the arbiter opened. Samples keep flowing while no window is open — the
    /// detectors are stateful and a real IMU does not stop between prompts.
    func ingest(_ sample: HeadMotionSample) {
        let result = pipeline.ingest(sample)
        if let gesture = result.gesture { onGesture?(gesture) }
        if let tap = result.tap { onTap?(tap) }
        if let tilt = result.tilt { onTilt?(tilt) }
        if let swipe = result.swipe {
            onSwipe?(swipe == .swipeUp ? .swipeUp : .swipeDown)
        }
    }

    private func openWindow() {
        guard !isOpen else { return }
        isOpen = true
        openedWindows += 1
    }
}

/// The voice channel as transcripts: speech-to-text is the platform's job, so the tested
/// surface starts at the grammar. Commands reach the arbiter only through the real
/// `VoiceCommandMatcher`, never as pre-built `VoiceCommand` values.
@MainActor
final class TranscriptVoiceChannel: VoiceCommandProviding {
    private var onCommand: (@MainActor (VoiceCommand) -> Void)?

    func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
        self.onCommand = onCommand
    }

    func stop() {
        onCommand = nil
    }

    func hear(_ transcript: String) {
        guard let command = VoiceCommandMatcher.match(transcript) else { return }
        onCommand?(command)
    }
}

@MainActor
final class RecordingSpeech: SpeechPresenting {
    private(set) var spoken: [(text: String, priority: SpeechPriority)] = []

    func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
        spoken.append((text, priority))
        onFinish?()
    }

    func stopAll() {}

    func said(_ text: String) -> Bool {
        spoken.contains { $0.text == text }
    }
}

final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TapQDiagnosticEvent] = []

    func record(_ event: TapQDiagnosticEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [TapQDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A `BrokerTransport` that hands request bytes to the broker in-process and returns the
/// response bytes, so a wire-level test needs no socket, no filesystem, and no thread.
final class InMemoryBrokerTransport: BrokerTransport, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case notStarted
    }

    private let lock = NSLock()
    private var handler: (@Sendable (Data) async -> Data)?

    func start(handler: @escaping @Sendable (Data) async -> Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    func deliver(_ request: Data) async throws -> Data {
        guard let handler = currentHandler() else { throw Failure.notStarted }
        return await handler(request)
    }

    private func currentHandler() -> (@Sendable (Data) async -> Data)? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}
