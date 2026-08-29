import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// `ask_about_work`: the sixth tool, the one that exists only where there is a transcript to
/// read.
///
/// Three properties are load-bearing here and each has its own test below. The tool is
/// *declared* only when an answerer exists, so on the Apple path it is not a disabled
/// feature but an undeclared one. A question resolves nothing, so the request the wearer was
/// asked is still on the table after they ask about the work. And the two failure classes
/// stay apart: a transcript TapQ cannot read is spoken out loud and the session lives, while
/// a cloud call that fails breaks the run's voice with nothing said.
@MainActor
final class AskAboutWorkTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
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

        var names: [String] { events.map(\.name) }
    }

    /// The same duplex fake the tool-intent suite uses, restated here so the two suites can
    /// drift independently.
    @MainActor
    private final class ToolBackend: VoiceBackend {
        let capabilities = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                    duplex: true,
                                                    supportsNativeTurnDetection: true,
                                                    supportsToolCalling: true)

        private(set) var declaredTools: [[String]] = []
        private(set) var toolResults: [(callID: String, output: String)] = []
        private(set) var scriptedSpeech: [String] = []
        private(set) var isOpen = false
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            isOpen = true
            handler = onEvent
        }

        func close() { isOpen = false }
        func beginUserTurn() {}

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool { expectingResponse }

        func sendAudio(_ chunk: VoiceAudioChunk) {}
        func requestResponse(text: String) {}
        func requestScriptedSpeech(text: String) { scriptedSpeech.append(text) }
        func cancelResponse() {}
        func setNativeTurnDetection(_ enabled: Bool) {}

        @discardableResult
        func requestModelTurn() -> Bool { true }

        func declareTools(_ tools: [VoiceToolDeclaration]) {
            declaredTools.append(tools.map(\.name))
        }

        func updateInstructions(_ instructions: String) {}

        func sendToolResult(callID: String, output: String) {
            toolResults.append((callID, output))
        }

        func emit(_ event: VoiceBackendEvent) {
            guard let handler else { return XCTFail("no session is listening") }
            handler(event)
        }
    }

    /// Records the questions asked and answers with whatever the test scripted.
    @MainActor
    private final class Answerer {
        var outcome: WorkQuestionOutcome
        private(set) var asked: [(question: String, agent: String?)] = []

        init(_ outcome: WorkQuestionOutcome) { self.outcome = outcome }

        func answer(_ question: String, _ agent: String?) async -> WorkQuestionOutcome {
            asked.append((question, agent))
            return outcome
        }
    }

    private func makeProvider(
        _ backend: ToolBackend,
        answerer: Answerer?,
        sink: RecordingSink = RecordingSink(),
        policy: SessionPolicy = .conversation(idleClose: 60)
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            intentSource: .modelToolCalls,
            sessionPolicy: policy,
            supportsBargeIn: true,
            answerWorkQuestion: answerer.map { answerer in
                { question, agent in await answerer.answer(question, agent) }
            },
            // Bounded rather than the shipped sixty seconds: an unbounded sleep left running
            // in-process stalls whichever test runs next.
            idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) },
            diagnosticSink: sink
        )
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func call(_ arguments: String, id: String = "call_1") -> VoiceBackendEvent {
        .toolCall(VoiceToolCall(callID: id, name: "ask_about_work", argumentsJSON: arguments))
    }

    // MARK: - Declaration

    /// The gate, and it is a declaration rather than a flag: with a transcript to read the
    /// model is offered six tools, and without one it is offered five and cannot ask for a
    /// sixth that does not exist.
    func testTheToolIsDeclaredOnlyWhenThereIsSomethingToAnswerFrom() async {
        let withTranscript = ToolBackend()
        _ = makeProvider(withTranscript, answerer: Answerer(.answered("x")))
        XCTAssertEqual(withTranscript.declaredTools, [[
            "approve", "deny", "select_item", "queue_instruction", "query_status",
            "ask_about_work",
        ]])

        let without = ToolBackend()
        _ = makeProvider(without, answerer: nil)
        XCTAssertEqual(without.declaredTools, [[
            "approve", "deny", "select_item", "queue_instruction", "query_status",
        ]])
    }

    /// The Apple path declares nothing at all — there is no model to declare to — so there
    /// is no composition in which the transcript tool exists beside a keyword grammar.
    func testTheGrammarPathDeclaresNoToolsAtAll() async {
        let backend = ToolBackend()
        _ = VoiceBackendCommandProvider(backend: backend, match: { _ in nil })
        XCTAssertEqual(backend.declaredTools, [])
    }

    /// A call for the tool on a composition that never declared it is the tool protocol
    /// being wrong, not a feature to switch on. Same treatment as any other undeclared name:
    /// the peer is answered so it is not parked, and the voice channel breaks.
    func testAskingWhereTheToolWasNeverDeclaredIsAProtocolFailure() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, answerer: nil, sink: sink)
        var failures: [String] = []
        provider.onIntentPipelineFailed = { failures.append($0) }

        provider.start { _ in }
        await settle()
        backend.emit(call(#"{"question":"what did you run?"}"#))
        await settle()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(backend.toolResults.count, 1, "the peer must not be left parked")
        XCTAssertTrue(backend.scriptedSpeech.isEmpty)
        XCTAssertTrue(sink.names.contains("tool.protocol_failed"))
    }

    // MARK: - The round trip

    /// Question in, answer out, spoken word for word on the channel every other TapQ
    /// sentence uses. The ordering is the real one: the wearer's turn is committed, the tool
    /// call arrives inside the response, and the answer goes out when that response is done.
    func testAQuestionIsAnsweredAndSpokenVerbatim() async {
        let backend = ToolBackend()
        let answerer = Answerer(.answered("One test failed, WireProtocolTests."))
        let sink = RecordingSink()
        let provider = makeProvider(backend, answerer: answerer, sink: sink)

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        backend.emit(call(#"{"question":"what did the tests say?","agent":"Claude Code"}"#))
        await settle()
        backend.emit(.responseCompleted)
        await settle()

        XCTAssertEqual(answerer.asked.count, 1)
        XCTAssertEqual(answerer.asked.first?.question, "what did the tests say?")
        XCTAssertEqual(answerer.asked.first?.agent, "Claude Code")
        XCTAssertEqual(backend.scriptedSpeech, ["One test failed, WireProtocolTests."])
        XCTAssertEqual(backend.toolResults.count, 1)
        XCTAssertEqual(backend.toolResults.first?.callID, "call_1")
        XCTAssertTrue(sink.names.contains("tool.ask_requested"), "\(sink.names)")
        XCTAssertTrue(sink.names.contains("ask.spoken"), "\(sink.names)")
    }

    /// A question resolves nothing. The approval the wearer was read is still open
    /// afterwards, and nothing was delivered to the window.
    func testAQuestionLeavesTheOpenWindowExactlyAsItFoundIt() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, answerer: Answerer(.answered("It ran the tests.")))
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()
        provider.endActiveTurn()
        backend.emit(call(#"{"question":"what did you run?"}"#))
        await settle()

        XCTAssertEqual(delivered, [], "a question must resolve nothing")
        XCTAssertTrue(provider.isWindowOpenForTesting, "the window was closed by a question")
    }

    /// Unlike the other five, this one needs no window: it delivers no command, so there is
    /// nothing for a window to receive, and refusing an answer because a prompt closed a beat
    /// earlier would only leave the wearer's question unanswered.
    func testAQuestionIsAnsweredWithNoWindowOpen() async {
        let backend = ToolBackend()
        let answerer = Answerer(.answered("It finished the migration."))
        let provider = makeProvider(backend, answerer: answerer)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"question":"what happened?"}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, ["It finished the migration."])
        XCTAssertEqual(answerer.asked.count, 1)
    }

    /// The agent argument is optional, and an omitted one arrives as nothing rather than as
    /// a guess.
    func testTheAgentIsOptionalAndNeverInvented() async {
        let backend = ToolBackend()
        let answerer = Answerer(.answered("ok"))
        let provider = makeProvider(backend, answerer: answerer)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"question":"what happened?"}"#))
        await settle()
        backend.emit(call(#"{"question":"and before that?","agent":"   "}"#, id: "call_2"))
        await settle()

        XCTAssertEqual(answerer.asked.map(\.agent), [nil, nil])
    }

    // MARK: - Unreadable transcript: loud, but alive

    /// The wearer hears why, the model is told the same fact in its own words, and nothing
    /// breaks. Killing a voice session over a file that rotated is the disproportionate
    /// answer this case exists to avoid.
    func testAnUnreadableTranscriptIsSpokenAndTheSessionSurvives() async {
        let backend = ToolBackend()
        let notice = "I can't see that session's history, so I can't answer that."
        let provider = makeProvider(backend, answerer: Answerer(.unavailable(notice)))
        var failures: [String] = []
        var intentFailures: [String] = []
        provider.onWorkAnswerFailed = { failures.append($0) }
        provider.onIntentPipelineFailed = { intentFailures.append($0) }

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"question":"what did you run?"}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, [notice])
        XCTAssertEqual(backend.toolResults.count, 1)
        XCTAssertTrue(failures.isEmpty, "an unreadable transcript is not a voice break")
        XCTAssertTrue(intentFailures.isEmpty)
    }

    // MARK: - Cloud failure: break, and say nothing

    /// The model family and endpoint are narration's, so the posture is narration's. TapQ
    /// says nothing — the latch speaks its own notice, and a sentence saying "I couldn't
    /// answer" would be the degraded half-answer this path does not have.
    func testACloudFailureBreaksTheRunAndSpeaksNothing() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, answerer: Answerer(.failed("timeout")), sink: sink)
        var failures: [String] = []
        provider.onWorkAnswerFailed = { failures.append($0) }

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"question":"what did you run?"}"#))
        await settle()

        XCTAssertEqual(failures, ["timeout"])
        XCTAssertTrue(backend.scriptedSpeech.isEmpty, "no half-answer may be spoken")
        XCTAssertEqual(backend.toolResults.count, 1, "the peer is still answered")
        let failed = sink.events.last { $0.name == "ask.failed" }
        XCTAssertEqual(failed?.level, .error)
    }

    /// The three hooks are separate on purpose: an operator reading the log has to know
    /// whether TapQ could not be heard, could not understand the wearer, or could not answer
    /// a question. They reach the same latch and mean different things.
    func testTheAnswerFailureHookIsNotTheIntentFailureHook() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, answerer: Answerer(.failed("http 500")))
        var intentFailures: [String] = []
        var speechFailures: [String] = []
        provider.onIntentPipelineFailed = { intentFailures.append($0) }
        provider.onScriptedSpeechUndeliverable = { speechFailures.append($0) }

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"question":"what did you run?"}"#))
        await settle()

        XCTAssertTrue(intentFailures.isEmpty)
        XCTAssertTrue(speechFailures.isEmpty)
    }

    // MARK: - Bad arguments

    /// Nothing to look up is a legal call that could not run — refused out loud, and the
    /// session survives it. The model is never asked a question TapQ did not hear.
    func testAnEmptyQuestionIsRefusedOutLoudAndNeverReachesTheAnswerer() async {
        let backend = ToolBackend()
        let answerer = Answerer(.answered("should not be reached"))
        let provider = makeProvider(backend, answerer: answerer)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"question":"   "}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, [VoiceIntentTools.emptyQuestionNotice])
        XCTAssertTrue(answerer.asked.isEmpty)
    }

    /// Arguments that cannot be read are the protocol being wrong, exactly as for the other
    /// five tools.
    func testUnreadableArgumentsAreAProtocolFailure() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, answerer: Answerer(.answered("x")))
        var failures: [String] = []
        provider.onIntentPipelineFailed = { failures.append($0) }

        provider.start { _ in }
        await settle()
        backend.emit(call("{not json"))
        await settle()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(backend.toolResults.count, 1)
    }

    // MARK: - The declaration's own words

    /// The description is the only place the boundary between this tool and `query_status`
    /// can be drawn, so both halves of it are pinned.
    func testTheDescriptionsSteerWorkQuestionsHereAndStatusQuestionsAway() async {
        let ask = VoiceIntentTools.askAboutWorkDeclaration
        XCTAssertEqual(ask.name, "ask_about_work")
        XCTAssertTrue(ask.description.contains("query_status"),
                      "the transcript tool must name the tool it is not")
        XCTAssertTrue(ask.description.lowercased().contains("session history"))

        let status = VoiceIntentTools.declarations.first { $0.name == "query_status" }
        XCTAssertEqual(status?.description.contains("not this tool"), true,
                       "query_status must point work questions away from itself")

        let byName = Dictionary(uniqueKeysWithValues: ask.parameters.map { ($0.name, $0) })
        XCTAssertEqual(byName["question"]?.required, true)
        XCTAssertEqual(byName["agent"]?.required, false)
    }

    /// The five ratified actions are unchanged by the sixth: nothing was renamed, nothing
    /// was reordered, and the tool that can end a session still does not exist.
    func testTheFiveRatifiedToolsAreUntouched() async {
        XCTAssertEqual(VoiceIntentTools.declarations.map(\.name),
                       ["approve", "deny", "select_item", "queue_instruction", "query_status"])
        for declaration in VoiceIntentTools.declarations(includingAskAboutWork: true) {
            for word in ["end", "quit", "exit", "shutdown", "kill", "sleep"] {
                XCTAssertFalse(declaration.name.contains(word),
                               "\(declaration.name) reads like a way out of the session")
            }
        }
    }
}
