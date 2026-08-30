import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The provider with its intent taken from the model rather than from the words.
///
/// Ratified 2026-08-28 and implemented here: on a model-backed session there is no keyword
/// matching, no heuristic, and no spoken way out of the voice session. What replaces them is
/// a tool call, executed once, answered once, and refused outright when there is nothing
/// listening for it.
@MainActor
final class VoiceBackendToolIntentTests: XCTestCase {
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
    }

    /// A duplex backend that records the tool traffic and replays scripted events.
    ///
    /// It answers `endUserTurn(expectingResponse: true)` with `true`, as a real duplex
    /// adapter does, so the provider's response-pending bookkeeping is exercised rather than
    /// short-circuited.
    @MainActor
    private final class ToolBackend: VoiceBackend {
        let capabilities = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                    duplex: true,
                                                    supportsNativeTurnDetection: true,
                                                    supportsToolCalling: true)

        private(set) var declaredTools: [[String]] = []
        private(set) var instructions: [String] = []
        private(set) var toolResults: [(callID: String, output: String)] = []
        private(set) var scriptedSpeech: [String] = []
        private(set) var endUserTurnExpectations: [Bool] = []
        private(set) var isOpen = false
        private(set) var isTurnActive = false
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            isOpen = true
            handler = onEvent
        }

        func close() {
            isOpen = false
            isTurnActive = false
        }

        func beginUserTurn() {
            XCTAssertTrue(isOpen, "beginUserTurn on a closed session")
            isTurnActive = true
        }

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool {
            endUserTurnExpectations.append(expectingResponse)
            isTurnActive = false
            return expectingResponse
        }

        func sendAudio(_ chunk: VoiceAudioChunk) {}
        func requestResponse(text: String) {}

        func requestScriptedSpeech(text: String) {
            scriptedSpeech.append(text)
        }

        func cancelResponse() {}
        func setNativeTurnDetection(_ enabled: Bool) {}

        private(set) var modelTurnRequests = 0
        /// Set to model a backend that declined to start a response.
        var grantsModelTurns = true

        @discardableResult
        func requestModelTurn() -> Bool {
            modelTurnRequests += 1
            return grantsModelTurns
        }

        func declareTools(_ tools: [VoiceToolDeclaration]) {
            declaredTools.append(tools.map(\.name))
        }

        func updateInstructions(_ instructions: String) {
            self.instructions.append(instructions)
        }

        func sendToolResult(callID: String, output: String) {
            toolResults.append((callID, output))
        }

        func emit(_ event: VoiceBackendEvent) {
            guard let handler else { return XCTFail("no window is listening") }
            handler(event)
        }
    }

    private func makeProvider(
        _ backend: ToolBackend,
        sink: RecordingSink = RecordingSink(),
        policy: SessionPolicy = .perWindow
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            intentSource: .modelToolCalls,
            sessionPolicy: policy,
            supportsBargeIn: true,
            // Bounded rather than the shipped sixty seconds: an unbounded sleep left running
            // in-process stalls whichever test runs next.
            idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) },
            diagnosticSink: sink
        )
    }

    private func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }

    private func call(_ name: String, _ arguments: String = "",
                      id: String = "call_1") -> VoiceBackendEvent {
        .toolCall(VoiceToolCall(callID: id, name: name, argumentsJSON: arguments))
    }

    // MARK: - Declaration

    /// Declared before any session exists, so the tool set rides the first frame of every
    /// session — including a reconnect's. A window that opened into the gap between a session
    /// coming up and its tools landing would hear the wearer and be unable to act on them.
    func testToolsAreDeclaredBeforeTheFirstSessionExists() async {
        let backend = ToolBackend()
        _ = makeProvider(backend)

        XCTAssertEqual(backend.declaredTools,
                       [VoiceIntentTools.declarations.map(\.name)])
        XCTAssertFalse(backend.isOpen, "nothing should have been opened yet")
    }

    /// The grammar path declares nothing. There is no model to declare to, and a frame sent
    /// at an Apple recognizer would be a frame with nowhere to go.
    func testTheGrammarPathDeclaresNoTools() async {
        let backend = ToolBackend()
        _ = VoiceBackendCommandProvider(backend: backend, match: { _ in nil })

        XCTAssertEqual(backend.declaredTools, [])
    }

    // MARK: - No transcript-derived intent

    /// The heart of the decision. Every one of these transcripts resolved a window before
    /// 2026-08-28 — the third is the one that ended a live session mid-test — and on this
    /// path not one of them may do anything at all.
    func testTranscriptsThatUsedToMatchNowDoNothing() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, sink: sink)
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()

        for transcript in ["yes", "approve", "no", "stop listening", "end voice session",
                           "tell Codex to run the tests", "who's waiting?"] {
            backend.emit(.transcriptFinal(transcript))
        }

        XCTAssertEqual(delivered, [], "a transcript resolved something on the model path")
        XCTAssertTrue(provider.isWindowOpenForTesting,
                      "no transcript may close the window on this path")
        XCTAssertTrue(sink.names.contains("transcript.observed"))
        XCTAssertFalse(sink.names.contains("command.matched"))
    }

    /// Free-form delivery is itself a transcript→intent step — an unmatched sentence promoted
    /// to a command — so it goes with the rest of them, `--voice-freeform` or not.
    func testFreeformIsNotDeliveredOnTheModelPath() async {
        let backend = ToolBackend()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            intentSource: .modelToolCalls,
            freeformEnabled: true
        )
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()
        backend.emit(.transcriptFinal("also update the changelog"))

        XCTAssertEqual(delivered, [])
    }

    /// Observers still hear the words, reported as what they are: heard, and acted on by
    /// nothing.
    func testTranscriptObserversStillFireAndReportNoMatch() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend)
        var observed: [(String, Bool)] = []
        provider.onTranscriptFinal = { observed.append(($0, $1)) }

        provider.start { _ in }
        await settle()
        backend.emit(.transcriptFinal("approve it"))

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, "approve it")
        XCTAssertEqual(observed.first?.1, false)
    }

    // MARK: - Execution

    func testEachToolResolvesItsWindowAndAnswersTheModel() async {
        let cases: [(event: VoiceBackendEvent, expected: VoiceCommand)] = [
            (call("approve"), .yes),
            (call("deny"), .no),
            (call("select_item", #"{"index":2}"#), .number(2)),
            (call("queue_instruction", #"{"text":"ship it"}"#), .beginInstruction("ship it")),
            (call("query_status", #"{"kind":"waiting"}"#), .status),
        ]
        for (event, expected) in cases {
            let backend = ToolBackend()
            let provider = makeProvider(backend)
            var delivered: [VoiceCommand] = []

            provider.start { delivered.append($0) }
            await settle()
            backend.emit(event)

            XCTAssertEqual(delivered, [expected])
            XCTAssertEqual(backend.toolResults.count, 1,
                           "every call is owed exactly one result")
            XCTAssertEqual(backend.toolResults.first?.callID, "call_1")
            XCTAssertFalse(provider.isWindowOpenForTesting,
                           "a resolved tool call closes its window")
        }
    }

    /// The result goes back before the window is resolved. Resolving cancels the response the
    /// call arrived in, and a peer whose response was cancelled with a call still open would
    /// wait on TapQ for the rest of the session.
    func testTheModelIsAnsweredBeforeTheWindowIsResolved() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend)
        var resultsAtDelivery = 0

        provider.start { _ in resultsAtDelivery = backend.toolResults.count }
        await settle()
        backend.emit(call("approve"))

        XCTAssertEqual(resultsAtDelivery, 1)
    }

    /// Rung E, reached through a tool argument instead of a spoken prefix. The address is on
    /// the sentence in the form the dictation flow's resolver reads, so the fail-closed
    /// unknown-agent refusal is the one that already shipped.
    func testAnAddressedInstructionArrivesInTheRungEForm() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend)
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()
        backend.emit(call("queue_instruction", #"{"agent":"Codex","text":"run the tests"}"#))

        XCTAssertEqual(delivered, [.beginInstruction("tell Codex to run the tests")])
    }

    // MARK: - Nothing listening

    /// A call that outlived its window: nothing happens, and the model is still answered.
    func testACallWithNoWindowIsRefusedRatherThanActedOn() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, sink: sink, policy: .conversation(idleClose: 60))
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()
        provider.stop()
        backend.emit(call("approve"))

        XCTAssertEqual(delivered, [])
        XCTAssertEqual(backend.toolResults.count, 1)
        XCTAssertTrue(sink.names.contains("tool.refused_no_window"))
    }

    /// A dictation the wearer just spoke into a closed window is refused *out loud*, in
    /// TapQ's own words on the verbatim channel — silence there is indistinguishable from a
    /// microphone that stopped working.
    func testARefusedDictationIsSpokenOnTheScriptedChannel() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, policy: .conversation(idleClose: 60))

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call("queue_instruction", #"{"text":"ship it"}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, [VoiceIntentTools.notListeningNotice])
    }

    // MARK: - Fail loud

    /// Malformed tool traffic ends the voice channel. It never falls back to reading the
    /// transcript: a tool protocol TapQ cannot parse says nothing about whether the words
    /// were understood, and guessing from them is what this path exists to have removed.
    func testMalformedToolTrafficBreaksThePipelineRatherThanDegrading() async {
        let broken: [VoiceBackendEvent] = [
            call("end_session"),
            call("select_item", "{not json"),
            call("query_status", "{}"),
        ]
        for event in broken {
            let backend = ToolBackend()
            let sink = RecordingSink()
            let provider = makeProvider(backend, sink: sink)
            var failures: [String] = []
            var delivered: [VoiceCommand] = []
            provider.onIntentPipelineFailed = { failures.append($0) }

            provider.start { delivered.append($0) }
            await settle()
            backend.emit(event)

            XCTAssertEqual(failures.count, 1, "\(event) did not break the pipeline")
            XCTAssertEqual(delivered, [], "a malformed call must resolve nothing")
            XCTAssertEqual(backend.toolResults.count, 1,
                           "even a malformed call is answered, so the peer is not parked")
            XCTAssertTrue(sink.names.contains("tool.protocol_failed"))
        }
    }

    /// A backend calling tools on a composition that declared none. TapQ does not know what
    /// it was asked for, and a channel inventing actions is the loudest kind of broken.
    func testAToolCallOnTheGrammarPathBreaksThePipeline() async {
        let backend = ToolBackend()
        let provider = VoiceBackendCommandProvider(backend: backend, match: { _ in nil })
        var failures: [String] = []
        provider.onIntentPipelineFailed = { failures.append($0) }

        provider.start { _ in XCTFail("nothing may be delivered") }
        await settle()
        backend.emit(call("approve"))

        XCTAssertEqual(failures.count, 1)
    }

    // MARK: - The no-AirPods path

    /// The wearer this decision was ratified for: no AirPods, so the backend's own VAD ends
    /// utterances and — by the carve-out's terms — creates no response. On the grammar path
    /// the commit produced a transcript and the transcript was the intent. Here a transcript
    /// is a log line, so something has to ask the model to act, or the session hears every
    /// word and does nothing with any of them.
    func testABackendCommitAsksTheModelToAct() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, sink: sink)

        provider.start { _ in }
        await settle()
        backend.emit(.userAudioCommittedByBackend)

        XCTAssertEqual(backend.modelTurnRequests, 1)
        XCTAssertEqual(backend.endUserTurnExpectations, [false],
                       "the buffer is already committed; no second commit may be asked for")
        XCTAssertTrue(sink.names.contains("turn.model_turn_requested"))
    }

    /// The microphone comes back when the model is done, so a wearer who is still talking is
    /// not cut off after one sentence. Bounded as ever by the window's own deadline.
    func testTheTurnReopensOnceTheModelHasAnswered() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend)

        provider.start { _ in }
        await settle()
        backend.emit(.userAudioCommittedByBackend)
        XCTAssertFalse(backend.isTurnActive)

        backend.emit(.responseCompleted)
        await settle()

        XCTAssertTrue(backend.isTurnActive, "the wearer got their microphone back")
    }

    /// A backend that declined leaves nothing to wait for, so the turn is reopened at once
    /// rather than left waiting on a `responseCompleted` that is never coming.
    func testADeclinedModelTurnReopensTheMicrophoneImmediately() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        backend.grantsModelTurns = false
        let provider = makeProvider(backend, sink: sink)

        provider.start { _ in }
        await settle()
        backend.emit(.userAudioCommittedByBackend)

        XCTAssertTrue(backend.isTurnActive)
        XCTAssertTrue(sink.names.contains("turn.model_turn_declined"))
    }

    /// Half-duplex still holds. A commit that lands while TapQ is speaking asks for nothing:
    /// the segment is in the conversation and the model reads it on the next turn.
    func testACommitDuringAResponseAsksForNothing() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend)

        provider.start { _ in }
        await settle()
        // Audio is proof a response is in flight — TapQ is mid-sentence.
        backend.emit(.audio(VoiceAudioChunk(data: Data([0, 1]), format: .pcm16Mono24k,
                                            timestamp: 0)))
        backend.emit(.userAudioCommittedByBackend)

        XCTAssertEqual(backend.modelTurnRequests, 0)
    }

    /// The grammar path is untouched: a native commit there is still a transcript on its way
    /// and nothing else.
    func testTheGrammarPathAsksForNoModelTurn() async {
        let backend = ToolBackend()
        let provider = VoiceBackendCommandProvider(backend: backend, match: { _ in nil })

        provider.start { _ in }
        await settle()
        backend.emit(.userAudioCommittedByBackend)

        XCTAssertEqual(backend.modelTurnRequests, 0)
        XCTAssertTrue(backend.isTurnActive, "the turn stays open on the grammar path")
    }

    // MARK: - Grounding

    /// The commit asks for a response, because a response is how the model gets to act: a
    /// tool call is an item inside one. On the grammar path it still asks for nothing.
    func testTheCommitAsksForAResponseOnlyOnTheModelPath() async {
        let toolBackend = ToolBackend()
        let toolProvider = makeProvider(toolBackend)
        toolProvider.start { _ in }
        await settle()
        toolProvider.endActiveTurn()
        XCTAssertEqual(toolBackend.endUserTurnExpectations, [true])

        let grammarBackend = ToolBackend()
        let grammarProvider = VoiceBackendCommandProvider(backend: grammarBackend,
                                                          match: { _ in nil })
        grammarProvider.start { _ in }
        await settle()
        grammarProvider.endActiveTurn()
        XCTAssertEqual(grammarBackend.endUserTurnExpectations, [false])
    }

    /// The grounding lands before the microphone does, and says an open window is waiting.
    func testGroundingIsSentBeforeTheTurnOpens() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend)

        provider.start { _ in }
        await settle()

        XCTAssertEqual(backend.instructions.count, 1)
        XCTAssertTrue(backend.instructions[0].contains("A TapQ window is open"),
                      "grounding: \(backend.instructions)")
    }

    /// What the model is told is what the wearer was just told — the same sentences, in the
    /// same order. Nothing about a request beyond the words TapQ spoke aloud can reach here,
    /// which is what makes the redaction rule structural.
    func testGroundingCarriesTheSentencesTheWearerJustHeard() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, policy: .conversation(idleClose: 60))
        provider.liveAgentNames = { ["Claude Code", "Codex"] }

        // A sentence with no session yet opens one for itself, exactly as a prompt spoken at
        // the top of a window does.
        provider.speakScripted("Run the migration? Nod or say yes.")
        await settle()
        XCTAssertEqual(backend.scriptedSpeech, ["Run the migration? Nod or say yes."])

        provider.start { _ in }
        // The window's turn waits for the sentence to finish; the grounding goes out with it.
        backend.emit(.responseCompleted)
        await settle()

        guard let grounding = backend.instructions.last else {
            return XCTFail("no grounding was sent")
        }
        XCTAssertTrue(grounding.contains("Run the migration? Nod or say yes."), grounding)
        XCTAssertTrue(grounding.contains("Claude Code, Codex"), grounding)
    }

    /// A window that ends takes its grounding with it. A model still told about a question
    /// that has already been answered would answer it again.
    func testGroundingIsClearedWhenTheWindowEnds() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, policy: .conversation(idleClose: 60))

        provider.speakScripted("Run the migration?")
        await settle()
        provider.start { _ in }
        backend.emit(.responseCompleted)
        await settle()
        provider.stop()

        provider.start { _ in }
        await settle()
        guard let grounding = backend.instructions.last else {
            return XCTFail("no grounding was sent")
        }
        XCTAssertFalse(grounding.contains("Run the migration?"), grounding)
    }

    /// A sentence is not over when its window is (2026-08-30).
    ///
    /// The wipe above was unconditional, and under `--voice-session` the eight-second window
    /// rotates while TapQ is still speaking: the read-back the wearer is listening to right
    /// now belonged to the window that just ended, so the next window's grounding told the
    /// model "TapQ has not said anything" about audio the wearer could hear. Whatever they
    /// said next then reached a model that did not know what it was an answer to.
    ///
    /// So the wipe waits for the audio rather than for the window. This is the rotation the
    /// arbiter performs when nothing resolved a window — `stopUnresolved` — with TapQ's own
    /// sentence still unfinished.
    func testGroundingSurvivesAWindowThatEndsWhileTapQIsStillSpeaking() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, policy: .conversation(idleClose: 60))

        provider.speakScripted("Queued for Claude Code: 'run the tests again.'")
        await settle()
        provider.start { _ in }
        await settle()
        // The clock came round. Nothing resolved the window and the sentence is still going.
        provider.stopUnresolved()
        await settle()

        provider.start { _ in }
        backend.emit(.responseCompleted)
        await settle()

        guard let grounding = backend.instructions.last else {
            return XCTFail("no grounding was sent")
        }
        XCTAssertTrue(grounding.contains("run the tests again"),
                      "the model was told nothing had been said: \(grounding)")
        XCTAssertFalse(
            grounding.contains("TapQ has not said anything"),
            "the wearer was listening to TapQ at that exact moment: \(grounding)"
        )
    }
}
