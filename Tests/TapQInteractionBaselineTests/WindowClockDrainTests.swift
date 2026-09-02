import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Sweep finding F3: the window's countdown and the window's microphone disagreed about when
/// the window began.
///
/// A command window set `deadline = now() + 8s` at controller entry and consulted nothing
/// about whether TapQ was still talking. It usually was — the previous window speaks its last
/// answer *as it closes*, and the voice-session loop opens the next window in the same actor
/// turn — so `SpeechGatedVoice` held the microphone shut through the first seconds of a
/// countdown that was already running. On hardware, 12 of 40 eight-second voice-session
/// windows opened with `[SpeechGate] microphone.held_closed`.
///
/// Every test here measures the quantity the wearer actually gets: **seconds of microphone
/// that can hear them**. `DrainAwareArbiter.micOpenSeconds` is that number per listen, and it
/// is the one the old code could make zero.
///
/// ## The doubles
///
/// Round one (`InstructionAnnouncementTests`) established the pair this file needs: an
/// utterance occupies the clock for as long as its text takes to say, and the arbiter cannot
/// hear the wearer until it drains. The part round one had to fake — *when TapQ's voice
/// stops* — is now production code, so ``SelfAudio`` models the audio and
/// `VoiceChannelDrain` reads it exactly as the runtime does: the live `isSpeaking` signal
/// `SpeechGatedVoice` gates on, plus the `SpokenPace` estimate for audio that has been
/// accepted but has not started sounding.
@MainActor
final class WindowClockDrainTests: XCTestCase {
    /// A 102-character answer: the F7 evidence, at the length that broke it. Eight and a half
    /// seconds of audio at `SpokenPace.charactersPerSecond`.
    private static let longAnswer =
        "The last thing that changed was the test suite, which is now passing on both of the "
        + "two platforms now."

    // MARK: - Doubles

    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }

        var names: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage.map(\.name)
        }

        func fields(of name: String) -> [[String: String]] {
            lock.lock(); defer { lock.unlock() }
            return storage.filter { $0.name == name }.map(\.fields)
        }
    }

    @MainActor
    private final class VirtualClock {
        private(set) var now: ContinuousClock.Instant = .now
        func advance(by seconds: TimeInterval) { now = now.advanced(by: .seconds(seconds)) }
        func advance(to instant: ContinuousClock.Instant) {
            guard instant > now else { return }
            now = instant
        }
    }

    /// TapQ's own voice, as both of the readings in `VoiceChannelDrain` see it.
    ///
    /// One object because they are one thing: `isSounding` is what the runtime's
    /// `SpeechActivitySignaling` reports, and `opensAt` is when `SpeechGatedVoice` would let
    /// the microphone back open. `playbackLatency` is the gap `SpokenTurnBudget` documents —
    /// a sentence the backend has accepted is not sounding yet, so for those milliseconds the
    /// live signal reads quiet about audio that is certainly coming.
    @MainActor
    private final class SelfAudio {
        private let clock: VirtualClock
        private var audibleFrom: ContinuousClock.Instant
        private(set) var quietAt: ContinuousClock.Instant
        var playbackLatency: TimeInterval = 0

        init(clock: VirtualClock) {
            self.clock = clock
            self.audibleFrom = clock.now
            self.quietAt = clock.now
        }

        /// TapQ handed a sentence to the voice channel. Utterances queue rather than overlap.
        func accepted(_ text: String) {
            guard !text.isEmpty else { return }
            let seconds = SpokenPace.drainSeconds(of: text)
            if clock.now >= quietAt {
                audibleFrom = clock.now.advanced(by: .seconds(playbackLatency))
                quietAt = audibleFrom.advanced(by: .seconds(seconds))
            } else {
                quietAt = quietAt.advanced(by: .seconds(seconds))
            }
        }

        /// The live `isSpeaking` reading.
        var isSounding: Bool { clock.now >= audibleFrom && clock.now < quietAt }

        /// When a listen opened now would first be able to hear the wearer.
        var opensAt: ContinuousClock.Instant { max(clock.now, quietAt) }
    }

    /// A voice that takes time to say things. `onFinish` still fires immediately — that is
    /// what `BackendSpeechSink` does, and why no caller can use it to sequence a listen.
    @MainActor
    private final class DrainingSpeech: SpeechPresenting {
        private let audio: SelfAudio
        private(set) var spoken: [String] = []

        init(audio: SelfAudio) { self.audio = audio }

        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(text)
            audio.accepted(text)
            onFinish?()
        }

        func stopAll() {}
    }

    /// An input window that spends real time and cannot hear through TapQ's own voice.
    @MainActor
    private final class DrainAwareArbiter: InputArbitrating {
        struct Answer {
            let intent: InputIntent?
            /// Seconds after the *microphone opens* before the wearer speaks or gestures.
            let after: TimeInterval
        }

        private let clock: VirtualClock
        private let audio: SelfAudio
        private let script: [Answer]
        private(set) var timeouts: [TimeInterval] = []
        /// The number this whole file is about: seconds of microphone that could actually
        /// hear the wearer. Zero is the bug.
        private(set) var micOpenSeconds: [TimeInterval] = []

        init(clock: VirtualClock, audio: SelfAudio, script: [Answer]) {
            self.clock = clock
            self.audio = audio
            self.script = script
        }

        func listen(timeout: TimeInterval) async -> InputIntent? {
            let index = timeouts.count
            timeouts.append(timeout)
            let expiresAt = clock.now.advanced(by: .seconds(timeout))
            // `SpeechGatedVoice`: the channel opens when the engine drains, not when the
            // listen starts.
            let opensAt = audio.opensAt
            micOpenSeconds.append(max(0, expiresAt.seconds(after: opensAt)))
            guard index < script.count, let intent = script[index].intent else {
                clock.advance(to: expiresAt)
                return nil
            }
            let heardAt = opensAt.advanced(by: .seconds(script[index].after))
            guard heardAt <= expiresAt else {
                clock.advance(to: expiresAt)
                return nil
            }
            clock.advance(to: heardAt)
            return intent
        }
    }

    // MARK: - Fixtures

    /// A voice-session window composed the way the runtime composes it: the shared drain
    /// record, reading the same live signal `SpeechGatedVoice` gates the microphone on.
    private func window(
        clock: VirtualClock,
        audio: SelfAudio,
        speech: DrainingSpeech,
        arbiter: DrainAwareArbiter,
        drain: VoiceChannelDrain,
        sink: RecordingSink,
        cue: String?,
        recall: RecallResponding? = nil
    ) -> CommandWindowController {
        let controller = CommandWindowController(
            speech: speech,
            arbiter: arbiter,
            gate: InteractionGate(),
            cue: cue,
            agentDisplayName: "Claude Code",
            diagnosticSink: sink,
            recallResponder: recall,
            kind: .voiceSession,
            voiceMayEndSession: false,
            voiceChannelDrain: drain,
            // The sweep this file reproduces was measured on eight-second windows, and the
            // clock rules it pins hold at any length.
            windowSeconds: CommandWindowController.windowSeconds
        )
        controller.now = { clock.now }
        // The deferral's sleep, virtualized: the wait is real seconds in the runtime and
        // clock ticks here.
        controller.drainSleep = { seconds in clock.advance(by: seconds) }
        return controller
    }

    private func drainRecord(_ audio: SelfAudio) -> VoiceChannelDrain {
        VoiceChannelDrain { audio.isSounding }
    }

    // MARK: - The clock starts at the drain edge

    /// The fix, in the shape the hardware produced the bug: a window opens while the previous
    /// window's closing sentence is still sounding, and the wearer who answers just after it
    /// stops is heard.
    ///
    /// Under the old clock this is the `microphone.held_closed` window: the countdown started
    /// at controller entry, the microphone opened eight seconds later, and the deadline had
    /// already passed when it did.
    func testAWindowOpeningUnderDrainAnchorsItsClockAtTheDrainEdge() async {
        let clock = VirtualClock()
        let audio = SelfAudio(clock: clock)
        let speech = DrainingSpeech(audio: audio)
        let drain = drainRecord(audio)
        let sink = RecordingSink()

        // The previous window's residual sentence: ninety-six characters, eight seconds.
        speech.speak(String(repeating: "a", count: 96), priority: .notification,
                     onFinish: nil)
        drain.willSpeak(String(repeating: "a", count: 96), at: clock.now)
        let opened = clock.now

        // The wearer answers half a second after the microphone can hear them.
        let arbiter = DrainAwareArbiter(clock: clock, audio: audio,
                                        script: [.init(intent: .status, after: 0.5)])
        let outcome = await window(clock: clock, audio: audio, speech: speech,
                                   arbiter: arbiter, drain: drain, sink: sink,
                                   cue: CommandWindowController.voiceSessionCue,
                                   recall: { _ in "Nothing waiting." }).run()

        XCTAssertEqual(outcome.answers, 1,
                       "the wearer answered after the drain and was not heard")
        XCTAssertGreaterThan(
            arbiter.micOpenSeconds[0], CommandWindowController.windowSeconds - 0.001,
            "the window gave the wearer less open microphone than it promises"
        )
        // The old clock would have expired here: the wearer was heard past the nominal
        // eight seconds from entry, which is exactly what the anchor bought them.
        XCTAssertGreaterThan(clock.now.seconds(after: opened),
                             CommandWindowController.windowSeconds,
                             "the answer landed inside the old deadline, so this proves nothing")
        let deferrals = sink.fields(of: "window.clock_deferred")
        XCTAssertEqual(deferrals.count, 1, "the deferral was not recorded")
        XCTAssertEqual(Double(deferrals[0]["signal_ms"] ?? "0") ?? 0, 8000, accuracy: 150,
                       "the deferral should be the eight seconds the live signal was busy")
    }

    /// The estimate's own job, and the reason the live signal is not enough on its own.
    ///
    /// A sentence the backend has accepted has not started sounding yet, so `isSpeaking`
    /// reads quiet for those milliseconds. A window anchored on the signal alone would sail
    /// straight through the gap and be back where it started.
    func testTheEstimateCoversAudioThatHasNotStartedSounding() async {
        let clock = VirtualClock()
        let audio = SelfAudio(clock: clock)
        audio.playbackLatency = 0.5
        let speech = DrainingSpeech(audio: audio)
        let drain = drainRecord(audio)

        // Handed over, accepted, not yet audible.
        let residual = String(repeating: "a", count: 60) // five seconds
        speech.speak(residual, priority: .notification, onFinish: nil)
        drain.willSpeak(residual, at: clock.now)
        XCTAssertFalse(audio.isSounding, "the fixture must start in the blind spot")

        let arbiter = DrainAwareArbiter(clock: clock, audio: audio,
                                        script: [.init(intent: .status, after: 0.5)])
        let outcome = await window(clock: clock, audio: audio, speech: speech,
                                   arbiter: arbiter, drain: drain, sink: RecordingSink(),
                                   cue: nil, recall: { _ in "Nothing waiting." }).run()

        XCTAssertEqual(outcome.answers, 1)
        XCTAssertGreaterThan(
            arbiter.micOpenSeconds[0], CommandWindowController.windowSeconds - 0.001,
            "the window counted through audio the live signal could not see yet"
        )
    }

    // MARK: - What the fix must not extend

    /// A window that opens into silence is the window it has always been: eight seconds of
    /// microphone, plus the commit allowance, and no deferral at all.
    func testAFullyOpenWindowStillTimesOutAtItsNominalLength() async {
        let clock = VirtualClock()
        let audio = SelfAudio(clock: clock)
        let speech = DrainingSpeech(audio: audio)
        let sink = RecordingSink()
        let opened = clock.now
        let arbiter = DrainAwareArbiter(clock: clock, audio: audio,
                                        script: [.init(intent: nil, after: 0)])

        let outcome = await window(clock: clock, audio: audio, speech: speech,
                                   arbiter: arbiter, drain: drainRecord(audio),
                                   sink: sink, cue: nil).run()

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(arbiter.timeouts.count, 1)
        XCTAssertEqual(arbiter.timeouts[0],
                       CommandWindowController.windowSeconds + WindowClock.commitAllowance,
                       accuracy: 0.001)
        XCTAssertEqual(clock.now.seconds(after: opened),
                       CommandWindowController.windowSeconds + WindowClock.commitAllowance,
                       accuracy: 0.001,
                       "a silent window must not outlive its own eight seconds")
        XCTAssertFalse(sink.names.contains("window.clock_deferred"),
                       "nothing was draining, so nothing should have been deferred")
    }

    /// The deferral is bounded. A signal stuck at `true` — a wedged synthesizer, a player
    /// that never reports idle — costs one window, not the session.
    func testAStuckSignalCannotHoldTheClockForever() async {
        let clock = VirtualClock()
        let audio = SelfAudio(clock: clock)
        let speech = DrainingSpeech(audio: audio)
        let sink = RecordingSink()
        let opened = clock.now
        // A signal that never goes quiet.
        let drain = VoiceChannelDrain { true }
        let arbiter = DrainAwareArbiter(clock: clock, audio: audio,
                                        script: [.init(intent: nil, after: 0)])

        _ = await window(clock: clock, audio: audio, speech: speech, arbiter: arbiter,
                         drain: drain, sink: sink, cue: nil).run()

        XCTAssertEqual(arbiter.timeouts.count, 1, "the window never opened a listen")
        let deferred = sink.fields(of: "window.clock_deferred")
        XCTAssertEqual(deferred.count, 1)
        XCTAssertLessThanOrEqual(
            Double(deferred[0]["drain_ms"] ?? "0") ?? 0,
            (WindowClock.maxDrainWait + WindowClock.drainPollInterval) * 1000,
            "the deferral ran past its bound"
        )
        XCTAssertLessThan(clock.now.seconds(after: opened),
                          WindowClock.maxDrainWait + CommandWindowController.windowSeconds
                              + WindowClock.commitAllowance + 1,
                          "a stuck signal held the gate longer than the bound allows")
    }

    // MARK: - F7: the residual listen

    /// Sweep finding F7, verified rather than assumed: a 102-character answer spoken into a
    /// 2.19-second residual listen.
    ///
    /// Anchoring the window's *birth* does not reach this — the answer is spoken in the
    /// middle of an already-open window — so the same rule has to hold for the listen that
    /// carries it: TapQ's own playback is not charged to the wearer's residue. Under the old
    /// sizing this listen expired more than six seconds before the microphone opened, so the
    /// answering window was not short, it was zero.
    func testAResidualListenAfterALongAnswerStillLeavesAnAnsweringWindow() async {
        let clock = VirtualClock()
        let audio = SelfAudio(clock: clock)
        let speech = DrainingSpeech(audio: audio)
        let sink = RecordingSink()
        XCTAssertEqual(SpokenPace.drainSeconds(of: Self.longAnswer), 8.5, accuracy: 0.1,
                       "the fixture answer is no longer the length the finding measured")

        // The wearer asks at 5.81 s, leaving 2.19 s of the window, and answers again half a
        // second after the answer stops sounding.
        let cue = CommandWindowController.voiceSessionCue
        let toAsk = 5.81 - SpokenPace.drainSeconds(of: cue)
        let arbiter = DrainAwareArbiter(
            clock: clock, audio: audio,
            script: [.init(intent: .whatChanged, after: toAsk),
                     .init(intent: .status, after: 0.5)]
        )
        let outcome = await window(clock: clock, audio: audio, speech: speech,
                                   arbiter: arbiter, drain: drainRecord(audio), sink: sink,
                                   cue: cue, recall: { _ in Self.longAnswer }).run()

        XCTAssertEqual(arbiter.timeouts.count, 2, "the residual listen never happened")
        XCTAssertGreaterThan(arbiter.micOpenSeconds[1], 2.19,
                             "the residual listen expired before the microphone opened")
        XCTAssertEqual(outcome.answers, 2,
                       "the wearer spoke into the residual window and was not heard")
        XCTAssertFalse(sink.names.contains("window.clock_deferred"),
                       "the window opened into silence; only the listen needed the fix")
    }

    // MARK: - F11: the commit allowance

    /// Sweep finding F11: the wearer speaks inside the window, and their turn commits about a
    /// second later — the detector's hangover plus `WearerTurnCoordinator`'s endpoint delay.
    /// A listen that closes exactly on the deadline throws that answer away.
    func testSpeechEndingJustInsideTheDeadlineStillCommits() async {
        let clock = VirtualClock()
        let audio = SelfAudio(clock: clock)
        let speech = DrainingSpeech(audio: audio)
        let opened = clock.now
        // Spoken inside the window; delivered 0.9 s after the nominal deadline.
        let commitsAt = CommandWindowController.windowSeconds + 0.9
        XCTAssertLessThan(commitsAt,
                          CommandWindowController.windowSeconds + WindowClock.commitAllowance,
                          "the fixture must land inside the allowance, not beyond it")
        let arbiter = DrainAwareArbiter(clock: clock, audio: audio,
                                        script: [.init(intent: .status, after: commitsAt)])

        let outcome = await window(clock: clock, audio: audio, speech: speech,
                                   arbiter: arbiter, drain: drainRecord(audio),
                                   sink: RecordingSink(), cue: nil,
                                   recall: { _ in "Nothing waiting." }).run()

        XCTAssertEqual(outcome.answers, 1,
                       "the wearer spoke inside the window and lost the turn to commit latency")
        XCTAssertGreaterThan(clock.now.seconds(after: opened),
                             CommandWindowController.windowSeconds,
                             "the fixture did not exercise the allowance")
        XCTAssertEqual(speech.spoken.last, "Nothing waiting.",
                       "the answer is still spoken once the window is over")
    }

    /// The allowance is a wait for an answer already given, not extra window. It is built from
    /// the two delays that actually elapse, read from the coordinator that owns one of them.
    func testTheCommitAllowanceIsTheEndpointDelayPlusTheHangover() async {
        XCTAssertEqual(WindowClock.commitAllowance,
                       WearerTurnCoordinator.defaultEndpointDelay + WindowClock.detectorHangover,
                       accuracy: 0.0001)
        XCTAssertEqual(WindowClock.commitAllowance, 1.0, accuracy: 0.0001)
    }

    // MARK: - The loop that opens windows

    /// The anti-spin invariant, over the sequence `VoiceSessionListening` runs: windows are
    /// re-opened for as long as a boundary is held, each one immediately after the last.
    ///
    /// Slow-draining audio used to make that loop churn — a window whose eight seconds were
    /// spent entirely on TapQ's own voice closed almost at once and the next one opened into
    /// the same audio. The invariant that forbids it is per-window and simple: no window
    /// completes having offered less than its eight seconds of microphone.
    func testTheVoiceSessionLoopDoesNotSpinWindowsWhileAudioDrains() async {
        let clock = VirtualClock()
        let audio = SelfAudio(clock: clock)
        let speech = DrainingSpeech(audio: audio)
        let drain = drainRecord(audio)
        let sink = RecordingSink()
        let started = clock.now
        var micPerWindow: [TimeInterval] = []

        // Four windows, as the loop opens them: the cue only on the first, and each window
        // leaving a long answer still sounding as it closes — the residual the sweep caught.
        for index in 0..<4 {
            let cue = index == 0 ? CommandWindowController.voiceSessionCue : nil
            // Asked late enough that the answer becomes the closing residual.
            let arbiter = DrainAwareArbiter(
                clock: clock, audio: audio,
                script: [.init(intent: .whatChanged,
                               after: CommandWindowController.windowSeconds + 0.5)]
            )
            _ = await window(clock: clock, audio: audio, speech: speech, arbiter: arbiter,
                             drain: drain, sink: sink, cue: cue,
                             recall: { _ in Self.longAnswer }).run()
            micPerWindow.append(arbiter.micOpenSeconds.reduce(0, +))
        }

        XCTAssertEqual(micPerWindow.count, 4)
        for (index, seconds) in micPerWindow.enumerated() {
            XCTAssertGreaterThan(
                seconds, CommandWindowController.windowSeconds - 0.001,
                "window \(index) offered \(seconds)s of open microphone, not its eight"
            )
        }
        // Every window after the first opened under the previous one's closing sentence, and
        // said so. The first opened into silence.
        XCTAssertEqual(sink.fields(of: "window.clock_deferred").count, 3,
                       "windows 2-4 open under the residual answer and must defer")
        // The rate follows: four drain-aware windows cannot fit in the wall time four
        // stolen ones did.
        XCTAssertGreaterThan(
            clock.now.seconds(after: started),
            4 * CommandWindowController.windowSeconds,
            "four windows completed in the time four stolen windows took — still spinning"
        )
    }
}
