import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// `start_task`: the seventh tool, and the only one that hands the wearer's words to
/// something that thinks about them (`docs/TAPQ_AGENT_PLAN.md`, Pillar C, milestone M2).
///
/// Four properties are load-bearing and each has its own test below. The tool is *declared*
/// only where a loop is composed, so on the Apple path and on every cloud run without one it
/// is not a disabled feature but an undeclared name. Whatever sentence the loop hands back is
/// spoken word for word — accepted and busy alike, because the contract in `WearerTask.swift`
/// says the caller speaks what comes back and does not compose sentences of its own. Nothing
/// is resolved, so the request the wearer was read is still open afterwards. And the reflex
/// six are untouched: adding a deliberation tier may not put a loop in the path of "approve".
@MainActor
final class StartTaskToolTests: XCTestCase {
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

    /// The same duplex fake the tool-intent and transcript suites use, restated here so the
    /// three can drift independently.
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

    /// A deliberation loop that records the goals it was offered and answers with whatever
    /// the test scripted. Nothing here runs a loop — what is under test is the seam.
    private final class Loop: WearerTaskStarting, @unchecked Sendable {
        private let start: WearerTaskStart
        /// Written inside `startTask` and read by the test after it has awaited the round
        /// trip, so the `await` is the ordering and no lock is needed — which also keeps this
        /// out of the "a lock taken across an await is an error in Swift 6" rule.
        nonisolated(unsafe) private(set) var goals: [String] = []

        init(_ start: WearerTaskStart) { self.start = start }

        func startTask(goal: String) async -> WearerTaskStart {
            goals.append(goal)
            return start
        }
    }

    private func makeProvider(
        _ backend: ToolBackend,
        loop: Loop?,
        answerer: (@MainActor (String, String?) async -> WorkQuestionOutcome)? = nil,
        sink: RecordingSink = RecordingSink(),
        policy: SessionPolicy = .conversation(idleClose: 60)
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            intentSource: .modelToolCalls,
            sessionPolicy: policy,
            supportsBargeIn: true,
            answerWorkQuestion: answerer,
            startWearerTask: loop,
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
        .toolCall(VoiceToolCall(callID: id, name: "start_task", argumentsJSON: arguments))
    }

    // MARK: - Declaration

    /// The gate, and it is a declaration rather than a flag: with a loop the model is offered
    /// the tool, and without one it is offered six and cannot ask for a seventh that does not
    /// exist.
    func testTheToolIsDeclaredOnlyWhenALoopIsComposed() async {
        let withLoop = ToolBackend()
        _ = makeProvider(withLoop, loop: Loop(.accepted(spoken: "ok")))
        XCTAssertEqual(withLoop.declaredTools, [[
            "approve", "deny", "select_item", "queue_instruction", "query_status",
            "start_task",
        ]])

        let without = ToolBackend()
        _ = makeProvider(without, loop: nil)
        XCTAssertEqual(without.declaredTools, [[
            "approve", "deny", "select_item", "queue_instruction", "query_status",
        ]])
    }

    /// The two conditional tools are on independent gates, because the seams are: a run may
    /// be able to read a transcript and have no loop, or the reverse, and neither implies the
    /// other. All seven only where both are composed.
    func testTheTwoConditionalToolsAreGatedSeparately() async {
        let both = ToolBackend()
        _ = makeProvider(both, loop: Loop(.accepted(spoken: "ok")),
                         answerer: { _, _ in .answered("x") })
        XCTAssertEqual(both.declaredTools, [[
            "approve", "deny", "select_item", "queue_instruction", "query_status",
            "ask_about_work", "start_task",
        ]])

        let askOnly = ToolBackend()
        _ = makeProvider(askOnly, loop: nil, answerer: { _, _ in .answered("x") })
        XCTAssertEqual(askOnly.declaredTools.first?.contains("start_task"), false)
        XCTAssertEqual(askOnly.declaredTools.first?.contains("ask_about_work"), true)
    }

    /// The Apple path declares nothing at all — there is no model to declare to — so there is
    /// no composition in which a deliberation tier exists beside a keyword grammar.
    func testTheGrammarPathDeclaresNoToolsAtAll() async {
        let backend = ToolBackend()
        _ = VoiceBackendCommandProvider(backend: backend, match: { _ in nil })
        XCTAssertEqual(backend.declaredTools, [])
    }

    /// A call for the tool where it was never declared is the tool protocol being wrong, not a
    /// loop that quietly did not run. Same treatment as any other undeclared name: the peer is
    /// answered so it is not parked, and the voice channel breaks.
    func testStartingATaskWhereTheToolWasNeverDeclaredIsAProtocolFailure() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, loop: nil, sink: sink)
        var failures: [String] = []
        provider.onIntentPipelineFailed = { failures.append($0) }

        provider.start { _ in }
        await settle()
        backend.emit(call(#"{"goal":"run the tests and tell me if anything fails"}"#))
        await settle()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(backend.toolResults.count, 1, "the peer must not be left parked")
        XCTAssertTrue(backend.scriptedSpeech.isEmpty)
        XCTAssertTrue(sink.names.contains("tool.protocol_failed"))
    }

    // MARK: - The round trip

    /// Goal in, acknowledgment out, spoken word for word on the channel every other TapQ
    /// sentence uses. The ordering is the real one: the wearer's turn is committed, the tool
    /// call arrives inside the response, and the sentence goes out when that response is done.
    func testAGoalIsHandedToTheLoopAndTheAcknowledgmentIsSpokenVerbatim() async {
        let backend = ToolBackend()
        let loop = Loop(.accepted(spoken: "I'm on it — running the tests now."))
        let sink = RecordingSink()
        let provider = makeProvider(backend, loop: loop, sink: sink)

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        backend.emit(call(#"{"goal":"run the tests and let me know if anything fails"}"#))
        await settle()
        backend.emit(.responseCompleted)
        await settle()

        XCTAssertEqual(loop.goals, ["run the tests and let me know if anything fails"])
        XCTAssertEqual(backend.scriptedSpeech, ["I'm on it — running the tests now."])
        XCTAssertEqual(backend.toolResults.count, 1)
        XCTAssertEqual(backend.toolResults.first?.callID, "call_1")
        XCTAssertTrue(sink.names.contains("tool.start_task_requested"), "\(sink.names)")
        XCTAssertTrue(sink.names.contains("task.accepted"), "\(sink.names)")
    }

    /// One task at a time is the contract's rule, and a refused goal is not queued. What the
    /// wearer hears is the loop's own sentence, verbatim — this provider composes nothing and
    /// so cannot describe a state it does not model.
    func testABusyLoopSaysSoAndTheSentenceIsSpokenVerbatim() async {
        let backend = ToolBackend()
        let busy = "I'm still on the last thing you asked — tell me again when I'm done."
        let loop = Loop(.busy(spoken: busy))
        let sink = RecordingSink()
        let provider = makeProvider(backend, loop: loop, sink: sink)
        var failures: [String] = []
        provider.onIntentPipelineFailed = { failures.append($0) }
        provider.onWorkAnswerFailed = { failures.append($0) }

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"goal":"tell Codex to do what Claude just did"}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, [busy])
        XCTAssertEqual(loop.goals, ["tell Codex to do what Claude just did"])
        XCTAssertEqual(backend.toolResults.count, 1, "the peer is answered either way")
        XCTAssertTrue(failures.isEmpty, "a busy loop is not a broken run")
        XCTAssertTrue(sink.names.contains("task.busy"), "\(sink.names)")
    }

    /// The tool result is for the model and the sentence is for the wearer, and they are not
    /// the same words. The output has to stop the model narrating a task it will not see the
    /// end of — nothing follows `sendToolResult`, so anything it said about the work would be
    /// said into a session with no response.
    func testTheModelIsToldTheTaskIsRunningAndToldToSayNothingFurther() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, loop: Loop(.accepted(spoken: "On it.")))

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"goal":"watch the build"}"#))
        await settle()

        let output = backend.toolResults.first?.output ?? ""
        XCTAssertTrue(output.contains("Say nothing further"), output)
        XCTAssertNotEqual(output, "On it.", "the model's record is not the wearer's sentence")
    }

    /// Starting a task resolves nothing. The approval the wearer was read is still open
    /// afterwards, and nothing was delivered to the window.
    func testStartingATaskLeavesTheOpenWindowExactlyAsItFoundIt() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, loop: Loop(.accepted(spoken: "On it.")))
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()
        provider.endActiveTurn()
        backend.emit(call(#"{"goal":"run the tests"}"#))
        await settle()

        XCTAssertEqual(delivered, [], "starting a task must resolve nothing")
        XCTAssertTrue(provider.isWindowOpenForTesting, "the window was closed by a task")
    }

    /// Like `ask_about_work` and unlike the other five, this one needs no window: it delivers
    /// no command, so there is nothing for a window to receive, and refusing a goal because a
    /// prompt closed a beat earlier would only lose the goal.
    func testAGoalIsTakenWithNoWindowOpen() async {
        let backend = ToolBackend()
        let loop = Loop(.accepted(spoken: "I'll find out and tell you."))
        let provider = makeProvider(backend, loop: loop)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"goal":"find out why the build broke"}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, ["I'll find out and tell you."])
        XCTAssertEqual(loop.goals.count, 1)
        XCTAssertFalse(provider.isWindowOpenForTesting)
    }

    /// The goal is the wearer's sentence and it reaches the loop unaltered, agent names and
    /// all. Nothing here parses it: which agent a goal is about is the loop's problem, and a
    /// provider that pre-chewed it would be a second grammar on the path that exists to have
    /// none.
    func testTheGoalReachesTheLoopWhole() async {
        let backend = ToolBackend()
        let loop = Loop(.accepted(spoken: "ok"))
        let provider = makeProvider(backend, loop: loop)
        let goal = "tell Codex to review what Claude just wrote, then tell me what it said"

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"goal":"\#(goal)"}"#))
        await settle()

        XCTAssertEqual(loop.goals, [goal])
    }

    // MARK: - Bad arguments

    /// Nothing to work on is a legal call that could not run — refused out loud, and the
    /// session survives it. The loop is never handed a goal TapQ did not hear.
    func testAnEmptyGoalIsRefusedOutLoudAndNeverReachesTheLoop() async {
        let backend = ToolBackend()
        let loop = Loop(.accepted(spoken: "should not be reached"))
        let provider = makeProvider(backend, loop: loop)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"goal":"   "}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, [VoiceIntentTools.emptyGoalNotice])
        XCTAssertTrue(loop.goals.isEmpty)
        XCTAssertEqual(backend.toolResults.count, 1, "the peer is still answered")
    }

    /// The refusal is the sentence a dictation that captured silence has always got. The
    /// wearer does not know which of the seven tools the model reached for, and a sentence
    /// that told them would be TapQ narrating its own routing.
    func testTheEmptyGoalRefusalIsTheOrdinarySayItAgain() async {
        XCTAssertEqual(VoiceIntentTools.emptyGoalNotice,
                       VoiceIntentTools.emptyInstructionNotice)
    }

    /// Arguments that cannot be read are the protocol being wrong, exactly as for the other
    /// six tools.
    func testUnreadableArgumentsAreAProtocolFailure() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, loop: Loop(.accepted(spoken: "ok")))
        var failures: [String] = []
        provider.onIntentPipelineFailed = { failures.append($0) }

        provider.start { _ in }
        await settle()
        backend.emit(call("{not json"))
        await settle()
        backend.emit(call("{}", id: "call_2"))
        await settle()

        XCTAssertEqual(failures.count, 2, "a missing goal field is not a goal")
        XCTAssertEqual(backend.toolResults.count, 2)
    }

    // MARK: - Diagnostics

    /// The goal is the wearer's own words. The log this provider writes has never held one,
    /// and the deliberation tier does not get to be the first.
    func testTheGoalIsLoggedByLengthAndNeverByContent() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let secret = "tell Claude to push the release key to the staging box"
        let provider = makeProvider(backend, loop: Loop(.accepted(spoken: "On it.")), sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call(#"{"goal":"\#(secret)"}"#))
        await settle()

        let requested = sink.events.first { $0.name == "tool.start_task_requested" }
        XCTAssertEqual(requested?.fields["length"], "\(secret.count)")
        for event in sink.events {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("staging box"),
                               "\(event.name) put the wearer's goal in the log")
            }
        }
    }

    // MARK: - The reflex tier is untouched

    /// The point of the two tiers is latency, so the test is that nothing changed for the six
    /// that were instant: a spoken "approve" still resolves its window in one call, with no
    /// loop anywhere in the path, on a provider that has a loop composed.
    func testApproveStillResolvesTheWindowDirectlyWithALoopComposed() async {
        let backend = ToolBackend()
        let loop = Loop(.accepted(spoken: "should not be reached"))
        let provider = makeProvider(backend, loop: loop)
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()
        backend.emit(.toolCall(VoiceToolCall(callID: "c1", name: "approve", argumentsJSON: "")))
        await settle()

        XCTAssertEqual(delivered, [.yes])
        XCTAssertTrue(loop.goals.isEmpty, "the reflex tier must not go through the loop")
    }

    // MARK: - The declaration's own words

    /// The description is the only place the boundary between a task and the reflex tools can
    /// be drawn, so the load-bearing halves of it are pinned: it names the tools it is not,
    /// it says the answer does not come back through the call, and it says that starting a
    /// task authorizes nothing.
    func testTheDescriptionSteersMultiStepGoalsHereAndSingleStepIntentsAway() async {
        let task = VoiceIntentTools.startTaskDeclaration
        XCTAssertEqual(task.name, "start_task")
        for reflex in ["approve", "deny", "select_item", "queue_instruction", "query_status"] {
            XCTAssertTrue(task.description.contains(reflex),
                          "the task tool must name the reflex tool it is not: \(reflex)")
        }
        XCTAssertTrue(task.description.lowercased().contains("more than one step"))
        XCTAssertTrue(task.description.lowercased().contains("authorizes nothing"),
                      "starting a task must not read like an approval")

        let byName = Dictionary(uniqueKeysWithValues: task.parameters.map { ($0.name, $0) })
        XCTAssertEqual(byName["goal"]?.required, true)
        XCTAssertEqual(task.parameters.count, 1, "a task takes a goal and nothing else")
    }

    /// It names no conditional tool. `ask_about_work` is composed on its own gate and may be
    /// absent from a run that has this one, and a description pointing at a tool the session
    /// never declared is an invitation to call it — which breaks the voice channel. The
    /// question boundary is drawn by behavior instead, exactly as `query_status` draws its
    /// half.
    func testTheDescriptionNamesNoToolThatMightNotBeDeclared() async {
        let task = VoiceIntentTools.startTaskDeclaration
        XCTAssertFalse(task.description.contains("ask_about_work"),
                       "a conditional tool must not be named by another conditional tool")
        XCTAssertTrue(task.description.lowercased().contains("session history"),
                      "the question boundary still has to be drawn, by behavior")
    }

    /// The steering added to the two neighbors points work *away* without naming a tool that
    /// may not exist, which is the same rule `query_status` was written under in M1.
    func testTheNeighborsSteerMultiStepRequestsAwayWithoutNamingTheTaskTool() async {
        let queue = VoiceIntentTools.declarations.first { $0.name == "queue_instruction" }
        XCTAssertEqual(queue?.description.contains("is not this tool"), true,
                       "dictation must point a look-something-up request away from itself")
        XCTAssertEqual(queue?.description.contains("start_task"), false)

        let ask = VoiceIntentTools.askAboutWorkDeclaration
        XCTAssertTrue(ask.description.contains("is not this tool"),
                      "a question tool must point a go-and-do request away from itself")
        XCTAssertFalse(ask.description.contains("start_task"))
    }

    /// The five ratified actions are unchanged by the seventh: nothing was renamed, nothing
    /// was reordered, and the tool that can end a session still does not exist.
    func testTheFiveRatifiedToolsAreUntouchedAndNothingEndsTheSession() async {
        XCTAssertEqual(VoiceIntentTools.declarations.map(\.name),
                       ["approve", "deny", "select_item", "queue_instruction", "query_status"])
        let all = VoiceIntentTools.declarations(includingAskAboutWork: true,
                                                includingStartTask: true)
        XCTAssertEqual(all.map(\.name), [
            "approve", "deny", "select_item", "queue_instruction", "query_status",
            "ask_about_work", "start_task",
        ])
        for declaration in all {
            for word in ["end", "quit", "exit", "shutdown", "kill", "sleep"] {
                XCTAssertFalse(declaration.name.contains(word),
                               "\(declaration.name) reads like a way out of the session")
            }
        }
    }

    // MARK: - Resolution, in isolation

    /// The pure half, enumerated the way `VoiceIntentToolsTests` enumerates the other six:
    /// undeclared is fatal, an unreadable or absent goal is fatal, a blank one is refused, and
    /// a real one produces the goal trimmed and otherwise untouched.
    func testResolutionEnumeratedWithoutAProvider() async {
        func resolve(_ arguments: String, declared: Bool = true,
                     windowOpen: Bool = true) -> VoiceIntentTools.Resolution {
            VoiceIntentTools.resolve(
                VoiceToolCall(callID: "c1", name: "start_task", argumentsJSON: arguments),
                windowOpen: windowOpen, startTaskDeclared: declared)
        }

        guard case .malformed = resolve(#"{"goal":"x"}"#, declared: false) else {
            return XCTFail("an undeclared start_task must be a protocol failure")
        }
        guard case .malformed = resolve("{not json") else {
            return XCTFail("unreadable arguments must be a protocol failure")
        }
        guard case .malformed = resolve("{}") else {
            return XCTFail("a missing goal must be a protocol failure")
        }
        guard case .refused(_, let speak) = resolve(#"{"goal":" \n "}"#) else {
            return XCTFail("a blank goal must be refused, not fatal")
        }
        XCTAssertEqual(speak, VoiceIntentTools.emptyGoalNotice)
        guard case .startTask(let goal) = resolve(#"{"goal":"  run the tests  "}"#) else {
            return XCTFail("a real goal must start a task")
        }
        XCTAssertEqual(goal, "run the tests")

        // And with nothing listening, which changes none of it.
        guard case .startTask = resolve(#"{"goal":"run the tests"}"#, windowOpen: false) else {
            return XCTFail("a task needs no open window")
        }
    }

    /// The gate defaults to closed. A caller that forgot the argument gets the Apple path's
    /// answer, not the loop's — the same fail direction every other gate on this path has.
    func testTheGateIsClosedByDefault() async {
        guard case .malformed = VoiceIntentTools.resolve(
            VoiceToolCall(callID: "c1", name: "start_task", argumentsJSON: #"{"goal":"x"}"#),
            windowOpen: true) else {
            return XCTFail("start_task must be undeclared unless a composition asked for it")
        }
        XCTAssertEqual(VoiceIntentTools.declarations(includingAskAboutWork: false).map(\.name),
                       ["approve", "deny", "select_item", "queue_instruction", "query_status"])
    }
}
