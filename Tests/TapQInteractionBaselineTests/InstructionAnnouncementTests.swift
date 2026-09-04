import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The 2026-08-30 fix, from both ends: an instruction the model resolved is announced rather
/// than confirmed, and wherever a confirmation *does* survive it is one the wearer can
/// actually give.
///
/// The bug was hardware-confirmed under `--voice-backend openai-realtime --voice-trust
/// environment --voice-session`. The wearer said "tell Claude Code to create a temporary
/// testing file…", the model called `queue_instruction`, the runtime routed it — and then
/// TapQ queued a 125-character read-back and re-listened with `timeout=1.96` left in the
/// window. TapQ's own playback holds the microphone closed for its drain
/// (`SpeechGatedVoice`), so the countdown ran out while the question was still being asked,
/// and the instruction was discarded `reason=silence`. Structurally, every time the read-back
/// outlasted the residue.
///
/// ## The double this file is built around
///
/// No test in this repo could fail on that bug, because every `SpeechPresenting` double
/// speaks instantaneously: `onFinish?()` fires immediately, no time passes, and the
/// microphone the runtime holds shut is never shut in a test. ``DrainingSpeech`` and
/// ``DrainAwareArbiter`` put that back — an utterance occupies the clock for as long as its
/// text takes to say, and the arbiter cannot hear the wearer until it drains. A listen
/// shorter than the sentence it is asking about therefore resolves as silence, exactly as it
/// did on hardware.
@MainActor
final class InstructionAnnouncementTests: XCTestCase {
    /// The sentence from the live log, at the length that broke it.
    private static let dictated =
        "Create a temporary testing file in the current directory, just a small empty file."

    // MARK: - Doubles

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

        func fields(of name: String) -> [[String: String]] {
            lock.lock()
            defer { lock.unlock() }
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

    /// A voice that takes time to say things, and a microphone that stays shut while it does.
    ///
    /// `onFinish` still fires immediately — that is what `BackendSpeechSink` does, and why no
    /// caller can use it to sequence a listen — but `quietAt` records when the audio actually
    /// stops, and utterances queue behind one another rather than overlapping.
    @MainActor
    private final class DrainingSpeech: SpeechPresenting {
        private let clock: VirtualClock
        private(set) var spoken: [String] = []
        /// When the last thing TapQ said stops sounding.
        private(set) var quietAt: ContinuousClock.Instant

        init(clock: VirtualClock) {
            self.clock = clock
            self.quietAt = clock.now
        }

        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(text)
            let starts = max(clock.now, quietAt)
            quietAt = starts.advanced(by: .seconds(SpokenPace.drainSeconds(of: text)))
            onFinish?()
        }

        func stopAll() { quietAt = clock.now }

        func said(containing needle: String) -> Bool {
            spoken.contains { $0.contains(needle) }
        }
    }

    /// An input window that spends real time and cannot hear through TapQ's own voice.
    ///
    /// Each scripted entry says what the wearer does and how long after the *microphone
    /// opens* they do it. The window resolves only if that moment falls inside the timeout it
    /// was given — which is the whole of the bug: a listen that expires during the drain
    /// hears nothing at all.
    @MainActor
    private final class DrainAwareArbiter: InputArbitrating {
        struct Answer {
            let intent: InputIntent?
            /// Seconds after the microphone opens before the wearer speaks or gestures.
            let after: TimeInterval
        }

        private let clock: VirtualClock
        private let speech: DrainingSpeech
        private let script: [Answer]
        private(set) var timeouts: [TimeInterval] = []
        /// Whether each listen ran out while TapQ was still speaking.
        private(set) var expiredWhileSpeaking: [Bool] = []
        var calls: Int { timeouts.count }

        init(clock: VirtualClock, speech: DrainingSpeech, script: [Answer]) {
            self.clock = clock
            self.speech = speech
            self.script = script
        }

        func listen(timeout: TimeInterval) async -> InputIntent? {
            let index = timeouts.count
            timeouts.append(timeout)
            let expiresAt = clock.now.advanced(by: .seconds(timeout))
            // `SpeechGatedVoice`: the channel opens when the engine drains, not when the
            // listen starts.
            let opensAt = max(clock.now, speech.quietAt)
            guard index < script.count, let intent = script[index].intent else {
                expiredWhileSpeaking.append(expiresAt < speech.quietAt)
                clock.advance(to: expiresAt)
                return nil
            }
            let heardAt = opensAt.advanced(by: .seconds(script[index].after))
            guard heardAt <= expiresAt else {
                expiredWhileSpeaking.append(expiresAt < speech.quietAt)
                clock.advance(to: expiresAt)
                return nil
            }
            expiredWhileSpeaking.append(false)
            clock.advance(to: heardAt)
            return intent
        }
    }

    @MainActor
    private final class Inbox {
        var queued: [String] = []
        var outcome: InstructionQueueOutcome = .queued
        var enqueue: InstructionDictating {
            { [self] text in queued.append(text); return outcome }
        }
    }

    // MARK: - Fixtures

    private func request() -> ApprovalRequest {
        ApprovalRequest(id: "1", sessionID: "s1", agent: .claudeCode, toolName: "Bash",
                        summary: "run npm test", detail: "full detail")
    }

    /// The live window, rebuilt: eight seconds, a sentence that takes six of them to say, and
    /// a residue too short to ask anything in.
    private func voiceSessionWindow(
        intentSource: VoiceIntentSource,
        clock: VirtualClock,
        arbiter: DrainAwareArbiter,
        speech: DrainingSpeech,
        sink: RecordingSink,
        inbox: Inbox
    ) -> CommandWindowController {
        let controller = CommandWindowController(
            speech: speech,
            arbiter: arbiter,
            gate: InteractionGate(),
            cue: CommandWindowController.voiceSessionCue,
            agentDisplayName: "Claude Code",
            diagnosticSink: sink,
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue,
            kind: .voiceSession,
            voiceTrust: .environment,
            voiceMayEndSession: false,
            gestureConfirmation: { false },
            intentSource: intentSource,
            // The races below were measured on eight-second windows and are reproduced at
            // that length. The rules they test are about the residue at the end of a window,
            // whichever length it has.
            windowSeconds: CommandWindowController.windowSeconds
        )
        controller.now = { clock.now }
        return controller
    }

    // MARK: - The model path announces

    /// The regression, in the shape the hardware produced it: the wearer's sentence leaves
    /// two seconds of window, and the instruction reaches the mailbox anyway.
    ///
    /// Nothing here waits for the wearer. There is no confirmation to expire, no silence to
    /// misread as a refusal, and no `instruction.discarded` — the sentence is delivered on
    /// routing and TapQ says what it did.
    func testAToolResolvedInstructionSurvivesAReadBackThatOutlastsTheWindow() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let sink = RecordingSink()
        let inbox = Inbox()
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(Self.dictated), after: 6.04)]
        )
        let outcome = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: sink, inbox: inbox
        ).run()

        XCTAssertEqual(inbox.queued, [Self.dictated],
                       "the instruction was lost to a window it never had to survive")
        XCTAssertEqual(outcome.dictations, 1)
        XCTAssertFalse(sink.names.contains("instruction.discarded"),
                       "nothing on this path may discard for silence: \(sink.names)")
        XCTAssertFalse(speech.said(containing: "queue it"),
                       "no confirmation may be asked for: \(speech.spoken)")
        XCTAssertTrue(speech.said(containing: "Queued for Claude Code:"),
                      "the wearer was not told what happened: \(speech.spoken)")
    }

    /// What the wearer hears: who it went to, and the sentence that went.
    ///
    /// The announcement carries the read-back because it *replaces* one — it is the only
    /// moment the wearer learns what was captured, and a bare "Queued for Claude Code."
    /// would leave a mis-transcription undetectable.
    func testTheAnnouncementNamesTheAgentAndSaysWhatWasQueued() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let inbox = Inbox()
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(Self.dictated), after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: inbox
        ).run()

        XCTAssertTrue(
            speech.said(containing: "Queued for Claude Code: '\(Self.dictated)'"),
            "spoke: \(speech.spoken)"
        )
    }

    /// A sentence too long to say in full is announced as shortened, never as though the
    /// whole of it had been read out: what was queued is the wearer's whole sentence, and the
    /// ellipsis is how they hear that the announcement is not all of it.
    func testALongInstructionIsAnnouncedAsShortened() async {
        let long = String(repeating: "run every single one of the integration tests ", count: 6)
            .trimmingCharacters(in: .whitespaces)
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let inbox = Inbox()
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(long), after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: inbox
        ).run()

        XCTAssertEqual(inbox.queued, [long], "the queued sentence is never the shortened one")
        XCTAssertTrue(speech.said(containing: "…'"),
                      "a shortened announcement must say so: \(speech.spoken)")
    }

    /// Truthfulness, unchanged by the new path: "Queued" is said about something that
    /// queued, and never about anything else.
    func testNothingIsCalledQueuedWhenTheMailboxTookNothing() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let inbox = Inbox()
        inbox.outcome = .notQueued
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(Self.dictated), after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: inbox
        ).run()

        XCTAssertFalse(speech.said(containing: "Queued for"),
                       "TapQ claimed to have queued something it did not: \(speech.spoken)")
        XCTAssertTrue(speech.said(containing: InstructionDictation.notQueuedNotice),
                      "the wearer was told nothing at all: \(speech.spoken)")
    }

    /// The drop-oldest disclosure survives the change: both facts are still spoken, in the
    /// clause the confirmed path has said since 2026-08-28.
    func testTheAnnouncementStillDisclosesADisplacedInstruction() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let inbox = Inbox()
        inbox.outcome = .queuedDroppingOldest
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(Self.dictated), after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: inbox
        ).run()

        XCTAssertEqual(inbox.queued, [Self.dictated])
        XCTAssertTrue(
            speech.said(containing: "This replaced the oldest waiting instruction."),
            "the displacement went unsaid: \(speech.spoken)"
        )
    }

    /// The wake word's outcome: nothing was live, so the sentence became a session instead
    /// of joining a queue. The wearer hears that, and not "Queued for …" — the two describe
    /// different things, and only one of them is what happened.
    func testAStartedSessionIsAnnouncedAsASessionAndNotAsAQueue() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let inbox = Inbox()
        inbox.outcome = .startedSession(agentDisplayName: "Claude Code")
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(Self.dictated), after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: inbox
        ).run()

        XCTAssertEqual(inbox.queued, [Self.dictated])
        XCTAssertTrue(speech.said(containing: "Started a new Claude Code session:"),
                      "the session went unannounced: \(speech.spoken)")
        XCTAssertFalse(speech.said(containing: "Queued for"),
                       "a started session was described as a queue: \(speech.spoken)")
        XCTAssertFalse(speech.said(containing: InstructionDictation.notQueuedNotice),
                       "the wearer was told it was lost: \(speech.spoken)")
    }

    /// And the goal is spoken, because on the announced path this is the wearer's only
    /// chance to hear what the session was started to do.
    func testTheStartedSessionAnnouncementCarriesTheGoal() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let inbox = Inbox()
        inbox.outcome = .startedSession(agentDisplayName: "Claude Code")
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction("set up a Swift package"), after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: inbox
        ).run()

        XCTAssertTrue(
            speech.said(containing:
                "Started a new Claude Code session: 'set up a Swift package.'"),
            "the goal went unsaid: \(speech.spoken)"
        )
    }

    /// The agent named is the one the *launch* produced, not the one the window was opened
    /// against. A wake window with nothing running addresses "the agent"; which agent it
    /// turned out to be is decided afterwards, and that is the name the wearer hears.
    func testTheAnnouncementNamesTheAgentTheOutcomeCarries() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let inbox = Inbox()
        inbox.outcome = .startedSession(agentDisplayName: "Codex")
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(Self.dictated), after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: inbox
        ).run()

        XCTAssertTrue(speech.said(containing: "Started a new Codex session:"),
                      "\(speech.spoken)")
        XCTAssertFalse(speech.said(containing: "Claude Code"), "\(speech.spoken)")
    }

    /// The diagnostic says which posture queued it, so a log can always tell an announced
    /// instruction from a confirmed one.
    func testTheQueuedDiagnosticRecordsThePosture() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let sink = RecordingSink()
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(Self.dictated), after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: sink, inbox: Inbox()
        ).run()

        XCTAssertEqual(sink.fields(of: "instruction.queued").map { $0["confirmation"] },
                       ["announced"])
    }

    /// An approval window on the model path: the sentence is queued in passing, and the
    /// wearer's next word answers the question they were actually asked.
    ///
    /// The other half of removing the confirmation. A "yes" no longer disappears into the
    /// dictation flow, so the input after a tool-resolved instruction resolves the request —
    /// which is what a wearer who has just been told "Queued" expects their next word to do.
    func testTheNextInputAfterAnAnnouncementAnswersTheRequest() async {
        let speech = InstantSpeech()
        let inbox = Inbox()
        let arbiter = ScriptedArbiter([.beginInstruction("run the tests again"), .allow])
        let controller = InteractionController(
            speech: speech, arbiter: arbiter,
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue,
            intentSource: .modelToolCalls
        )

        let decision = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, ["run the tests again"])
        XCTAssertEqual(decision, .allow,
                       "the allow was consumed by a confirmation nobody asked for")
        XCTAssertEqual(arbiter.calls, 2)
    }

    // MARK: - The grammar path keeps its confirmation, and can answer it

    /// The deadline half of the fix, and the test that fails without it.
    ///
    /// Same window, same residue: two seconds left when the read-back is spoken. The wearer
    /// answers a second after the microphone opens — which it does only when TapQ's own
    /// sentence has drained, some ten seconds in. A listen sized to the residue never hears
    /// them; a listen sized to its own question does.
    func testAConfirmationIsAskedWithEnoughTimeToAnswerIt() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let sink = RecordingSink()
        let inbox = Inbox()
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .freeform(Self.dictated), after: 6.04),
                     .init(intent: .allow, after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .transcriptGrammar, clock: clock, arbiter: arbiter,
            speech: speech, sink: sink, inbox: inbox
        ).run()

        XCTAssertTrue(speech.said(containing: "Instruction: 'Create a temporary"),
                      "spoke: \(speech.spoken)")
        XCTAssertTrue(speech.said(containing: "Say yes to queue it."),
                      "the grammar path must still ask: \(speech.spoken)")
        XCTAssertEqual(inbox.queued, [Self.dictated],
                       "the wearer answered and was not heard: \(arbiter.timeouts)")
        XCTAssertEqual(sink.fields(of: "instruction.queued").map { $0["confirmation"] },
                       ["confirmed"])
        XCTAssertEqual(arbiter.expiredWhileSpeaking, [false, false],
                       "no listen may run out while TapQ is still talking")
    }

    /// The listen is sized from the question, not from the window: it covers the read-back's
    /// own playback and then leaves a real answering window.
    func testTheConfirmationListenOutlastsItsOwnReadBack() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .freeform(Self.dictated), after: 6.04),
                     .init(intent: .allow, after: 1)]
        )
        _ = await voiceSessionWindow(
            intentSource: .transcriptGrammar, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: Inbox()
        ).run()

        XCTAssertEqual(arbiter.timeouts.count, 2, "timeouts: \(arbiter.timeouts)")
        XCTAssertLessThan(CommandWindowController.windowSeconds - 6.04, 2.0,
                          "the fixture must reproduce the race")
        let readBack = speech.spoken.first { $0.hasPrefix("Instruction:") }
        XCTAssertNotNil(readBack)
        let needed = SpokenPace.drainSeconds(of: readBack) + SpokenPace.answeringSeconds
        XCTAssertGreaterThanOrEqual(
            arbiter.timeouts[1], needed,
            "the confirmation was asked with less time than it takes to ask it"
        )
    }

    /// The confirmation still means something: a read-back nobody answers queues nothing.
    /// The grammar path guesses at intent, and the read-back is the only thing that catches a
    /// wrong guess.
    func testAnUnansweredReadBackStillQueuesNothingAndSaysSo() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let sink = RecordingSink()
        let inbox = Inbox()
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .freeform(Self.dictated), after: 6.04)]
        )
        _ = await voiceSessionWindow(
            intentSource: .transcriptGrammar, clock: clock, arbiter: arbiter,
            speech: speech, sink: sink, inbox: inbox
        ).run()

        XCTAssertEqual(inbox.queued, [], "an unconfirmed sentence must not be queued")
        XCTAssertEqual(sink.fields(of: "instruction.discarded").map { $0["reason"] },
                       ["silence"])
        // The 2026-08-30 sweep's second finding: this discard used to be mute, so a wearer
        // who dictated and heard nothing could not tell a lost sentence from a queued one.
        XCTAssertTrue(speech.said(containing: InstructionDictation.discardedNotice),
                      "the discard was silent: \(speech.spoken)")
    }

    /// The same silent discard inside an approval window, where the window is over by the
    /// time there is anything to say. The notice is spoken before the deferral rather than
    /// dropped with the window.
    func testASilentDiscardIsSpokenEvenWhenTheApprovalWindowIsOver() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let sink = RecordingSink()
        let inbox = Inbox()
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(Self.dictated), after: 1)]
        )
        let controller = InteractionController(
            speech: speech, arbiter: arbiter, diagnosticSink: sink,
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue,
            gestureConfirmation: { false }
        )
        controller.now = { clock.now }
        controller.entryMargin = 0

        let decision = await controller.resolve(request(),
                                                deadline: clock.now.advanced(by: .seconds(20)))

        XCTAssertEqual(decision, .ask, "an unanswered approval still defers to the screen")
        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: InstructionDictation.discardedNotice),
                      "the discard was silent: \(speech.spoken)")
        XCTAssertEqual(sink.fields(of: "instruction.discarded").map { $0["reason"] },
                       ["silence"])
    }

    // MARK: - What the fix must not extend

    /// A window with nothing to confirm is the eight-second window it has always been.
    ///
    /// "Eight seconds" is eight seconds of microphone the wearer can speak into. The listen
    /// covers the cue's own playback on top of that (sweep finding F3: TapQ's voice is not
    /// charged to the wearer) and the commit allowance (F11), and neither is answering time —
    /// what this test guards is that the turn does not get `TurnBudget.afterSpeaking`'s six
    /// seconds, which is what would turn the window into an open microphone.
    func testAnOrdinaryTurnStillGetsOnlyTheWindow() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let arbiter = DrainAwareArbiter(clock: clock, speech: speech,
                                        script: [.init(intent: nil, after: 0)])
        _ = await voiceSessionWindow(
            intentSource: .modelToolCalls, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: Inbox()
        ).run()

        XCTAssertEqual(arbiter.timeouts.count, 1)
        XCTAssertEqual(
            arbiter.timeouts[0],
            SpokenPace.drainSeconds(of: CommandWindowController.voiceSessionCue)
                + CommandWindowController.windowSeconds + WindowClock.commitAllowance,
            accuracy: 0.01
        )
        XCTAssertLessThan(arbiter.timeouts[0],
                          CommandWindowController.windowSeconds + SpokenPace.answeringSeconds,
                          "an ordinary turn was given a confirmation turn's answering window")
    }

    /// The dictation cue is not a question about a sentence the wearer has already said, so
    /// it takes the window's residue exactly as it always did. Extending every turn would
    /// turn an eight-second window into an open microphone.
    func testTheCaptureCueDoesNotExtendTheWindow() async {
        let clock = VirtualClock()
        let speech = DrainingSpeech(clock: clock)
        let arbiter = DrainAwareArbiter(
            clock: clock, speech: speech,
            script: [.init(intent: .beginInstruction(nil), after: 6.04),
                     .init(intent: nil, after: 0)]
        )
        _ = await voiceSessionWindow(
            intentSource: .transcriptGrammar, clock: clock, arbiter: arbiter,
            speech: speech, sink: RecordingSink(), inbox: Inbox()
        ).run()

        XCTAssertGreaterThanOrEqual(arbiter.timeouts.count, 2,
                                    "timeouts: \(arbiter.timeouts)")
        // The residue is still all the *window* the cue turn gets. What it also gets, and
        // what no amount of window would have covered, is its own playback and the commit
        // allowance — see `WindowClock`. Neither is answering time, which is the thing this
        // test exists to keep the cue turn from being handed.
        XCTAssertLessThanOrEqual(
            arbiter.timeouts[1],
            SpokenPace.drainSeconds(of: InstructionDictation.cue)
                + (CommandWindowController.windowSeconds - 6.04)
                + WindowClock.commitAllowance + 0.001,
            "the cue turn took more than the window had left"
        )
        XCTAssertLessThan(arbiter.timeouts[1], SpokenPace.answeringSeconds,
                          "the cue turn was given an answering window it did not ask for")
    }

    // MARK: - Plain doubles, for the tests that are not about time

    @MainActor
    private final class InstantSpeech: SpeechPresenting {
        var spoken: [String] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(text)
            onFinish?()
        }
        func stopAll() {}
    }

    @MainActor
    private final class ScriptedArbiter: InputArbitrating {
        private let script: [InputIntent?]
        private(set) var calls = 0
        init(_ script: [InputIntent?]) { self.script = script }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }
}
