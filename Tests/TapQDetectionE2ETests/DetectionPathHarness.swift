// The end-to-end detection-path suite.
//
// Every test in this target feeds generated IMU sample streams (and, for voice, transcript
// strings) into the real detection-to-decision stack and asserts on what comes out the far
// end: a `Decision`, a `SelectionResult`, or broker response bytes. Nothing between the
// sample and the answer is faked — the pipeline, analyzers, arbiters, controllers, voice
// grammar, wearer gate, and broker are all the shipping implementations. Only the edges are
// substituted: the motion source, the recognizer, the speech output, and the clocks.
//
// What the suite guarantees: the layers stay wired together, the shipped configs stay
// capable of detecting a plainly-shaped gesture, the default-off flags stay off, and the
// decision logic (first-wins arbitration, confirmation channels, timeout outcomes,
// attribution, turn control) keeps behaving as specified. Any change that breaks one of
// those fails here rather than on someone's head.
//
// What it does not guarantee: real-world accuracy. Every trace is shaped by construction,
// generated well clear of the thresholds it needs to cross or stay under, so the suite says
// nothing about how a real nod on real hardware compares to a real threshold. The capture
// study remains the accuracy gate for every IMU default; these tests are a regression net
// for wiring, config, and logic, and are worthless as evidence that a threshold is correct.

import Foundation
import XCTest
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
    /// What the arbiters actually listen to: the transcript channel itself by default, or
    /// whatever decorator a test wrapped around it (M2's wearer gate).
    let gatedVoice: VoiceCommandProviding
    let inputArbiter: InputArbiter
    let selectionArbiter: SelectionArbiter
    let interaction: InteractionController
    let selection: SelectionController

    /// The stream clock: where the next fed sample lands.
    private var cursor = TraceGenerators.epoch

    /// - Parameters:
    ///   - configure: Applied to the pipeline the harness builds, for tests that need a
    ///     non-default detector config. The pipeline is constructed here rather than
    ///     accepted whole so it always reports into `diagnostics`, which is where analyzer
    ///     rejection reasons are asserted.
    ///   - voiceGate: Wraps the transcript channel before the arbiters see it, for tests of
    ///     the M2 decorators. It receives the harness's sink so a decorator's own verdicts
    ///     land in the same event stream as the arbiter's. The default adds nothing.
    ///   - recallResponder: Answers spoken recall questions, as the runtime's conversation
    ///     memory does. Absent by default, which is every composition written before Rung B.
    ///   - freeformResponder: Answers a question spoken into an approval window. Absent by
    ///     default, which is the Apple path and every run without `--voice-freeform`.
    ///   - instructionCapability: Whether the agent behind the window can be instructed at
    ///     all, as the runtime's capability table answers it.
    ///   - wearerAttribution: Whether the voice that just spoke is provably the wearer's.
    ///     Absent means no, which is the fail-closed default the whole path takes.
    ///   - instructionEnqueue: Where a confirmed instruction goes. Absent by default —
    ///     that absence *is* the missing `--voice-instructions`, and every test that does
    ///     not pass one is asserting on the grammar being inert.
    init(configure: (inout MotionGesturePipeline) -> Void = { _ in },
         voiceGate: @MainActor (TranscriptVoiceChannel, RecordingSink) -> VoiceCommandProviding
             = { channel, _ in channel },
         recallResponder: RecallResponding? = nil,
         freeformResponder: FreeformQuestionResponding? = nil,
         instructionCapability: InstructionCapabilityChecking? = nil,
         wearerAttribution: WearerAttributionQuerying? = nil,
         instructionEnqueue: InstructionDictating? = nil) {
        var pipeline = MotionGesturePipeline(diagnosticSink: diagnostics)
        configure(&pipeline)
        let inputs = PipelineInputAdapter(pipeline: pipeline)
        self.inputs = inputs
        let gatedVoice = voiceGate(voice, diagnostics)
        self.gatedVoice = gatedVoice
        let timeouts = self.timeouts
        let sleep: @MainActor (TimeInterval) async -> Void = { await timeouts.sleep($0) }
        inputArbiter = InputArbiter(
            gestures: inputs, voice: gatedVoice, taps: inputs,
            diagnosticSink: diagnostics, timeoutSleep: sleep
        )
        selectionArbiter = SelectionArbiter(
            voice: gatedVoice, tilts: inputs, swipes: inputs, taps: inputs, gestures: inputs,
            diagnosticSink: diagnostics, timeoutSleep: sleep
        )
        interaction = InteractionController(
            speech: speech, arbiter: inputArbiter, diagnosticSink: diagnostics,
            recallResponder: recallResponder, freeformResponder: freeformResponder,
            instructionCapability: instructionCapability,
            wearerAttribution: wearerAttribution,
            instructionEnqueue: instructionEnqueue
        )
        selection = SelectionController(
            speech: speech, arbiter: selectionArbiter, diagnosticSink: diagnostics,
            recallResponder: recallResponder,
            instructionCapability: instructionCapability,
            wearerAttribution: wearerAttribution,
            instructionEnqueue: instructionEnqueue
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

    /// Delivers an unmatched transcript as the free-form command the realtime provider
    /// would deliver for it. See `TranscriptVoiceChannel.hearFreeform`.
    func hearFreeform(_ transcript: String) {
        voice.hearFreeform(transcript)
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

    /// Fails if any window ended on `ManualTimeout`'s watchdog. Call it after awaiting a
    /// decision a fed trace was supposed to produce: the outcome assertion already goes red
    /// when detection fails, but this one says why — nothing the trace produced ever reached
    /// the arbiter, so the window ran out instead of being answered.
    func assertWatchdogDidNotFire(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            timeouts.watchdogTripped,
            """
            a window ran the full \(ManualTimeout.watchdogSeconds)s watchdog: no detection \
            reached the arbiter
            """,
            file: file, line: line
        )
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
    /// The bound on a window nobody ever closes. Without it, a trace that stops being
    /// detected — a drifted threshold, an unwired channel — leaves the arbiter waiting on a
    /// timer that only a test can fire, and the awaiting test blocks until CI kills the job
    /// instead of going red. This ends the window in bounded real time so the outcome
    /// assertions get to run and fail.
    ///
    /// A passing run never reaches it: detections resolve the window synchronously inside
    /// `feed(_:)`, which cancels the timer. It can only fire once detection has failed, so
    /// it costs green-path determinism nothing and can be generous.
    static let watchdogSeconds: TimeInterval = 20

    private(set) var requested: [TimeInterval] = []
    /// Whether any window in this harness ended on the watchdog rather than on a detection
    /// or an `expire()`. Assert on it to name the cause; see `assertWatchdogDidNotFire`.
    private(set) var watchdogTripped = false
    private var expired = false

    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.watchdogSeconds))
        while !Task.isCancelled {
            if expired {
                expired = false
                return
            }
            if ContinuousClock.now >= deadline {
                watchdogTripped = true
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

    /// Delivers an unmatched transcript as the free-form command.
    ///
    /// The one command the grammar cannot produce: on device it is
    /// `VoiceBackendCommandProvider` that turns a final transcript matching no keyword
    /// into `.freeform`, once per turn and only under `--voice-freeform`. This restates
    /// that delivery so a portable test can reach the paths behind it; the matcher is
    /// still consulted first, because a transcript the grammar *does* know would never
    /// arrive here.
    func hearFreeform(_ transcript: String) {
        guard VoiceCommandMatcher.match(transcript) == nil else {
            XCTFail("'\(transcript)' matches the grammar and would never be free-form")
            return
        }
        onCommand?(.freeform(transcript))
    }
}

/// A real `WearerSpeechMonitor` presented as the `WearerSpeechSignaling` contract.
///
/// The shipping presenter, `WearerSpeechSignalSource`, lives in the Apple-only adapter
/// layer and is out of reach of a portable test target, so this restates its two rules —
/// speaking is the monitor's state, availability is fresh-and-per-axis — and forwards the
/// monitor's transitions. Every answer it gives is the real detector's; nothing here
/// decides anything about speech.
@MainActor
final class MonitorSpeechSignal: WearerSpeechSignaling {
    let monitor: WearerSpeechMonitor

    var isWearerSpeaking: Bool { monitor.state == .speaking }

    /// Mirrors `WearerSpeechSignalSource.isSignalAvailable` minus its `isAttached` flag,
    /// which is an attachment bookkeeping bit the source's owner sets; here the monitor is
    /// attached by construction.
    var isSignalAvailable: Bool {
        monitor.isFresh() && monitor.lastSampleHadPerAxisData
    }

    var onWearerSpeakingChange: (@MainActor (Bool) -> Void)?

    init(monitor: WearerSpeechMonitor) {
        self.monitor = monitor
        monitor.onTransition = { [weak self] _ in
            guard let self else { return }
            self.onWearerSpeakingChange?(self.monitor.state == .speaking)
        }
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
