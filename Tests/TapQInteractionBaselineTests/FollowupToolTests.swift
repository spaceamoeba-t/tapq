import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// `set_followup` and `cancel_followup`: the eighth and ninth realtime tools, and the only
/// ones that ask TapQ to remember something for later (`docs/TAPQ_AGENT_PLAN.md`, "Initiative
/// (M3, the guarded step)", scoped to one-shots 2026-08-31).
///
/// The properties that carry weight here are `start_task`'s, restated for a tool whose whole
/// point is that nothing happens now. They are declared only where a book is composed, and
/// declared *together*, because a wearer who can arm a promise and cannot call it off is
/// worse off than one who cannot arm it. Whatever sentence the book hands back is spoken word
/// for word. Nothing is resolved. And the reflex tools are untouched.
@MainActor
final class FollowupToolTests: XCTestCase {
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

    /// The same duplex fake the neighboring tool suites use, restated here so they can drift
    /// independently.
    @MainActor
    private final class ToolBackend: VoiceBackend {
        let capabilities = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                    duplex: true,
                                                    supportsNativeTurnDetection: true,
                                                    supportsToolCalling: true)

        private(set) var declaredTools: [[String]] = []
        private(set) var toolResults: [(callID: String, output: String)] = []
        private(set) var scriptedSpeech: [String] = []
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            handler = onEvent
        }

        func close() {}
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

    /// A book that records what it was asked and answers with whatever the test scripted.
    /// Nothing here holds a follow-up — what is under test is the seam.
    private final class Book: WearerFollowupScheduling, @unchecked Sendable {
        private let answer: WearerFollowupAcknowledgment
        /// Written inside the seam and read after the test has awaited the round trip, so the
        /// `await` is the ordering and no lock is needed — which also keeps this clear of the
        /// "a lock taken across an await is an error in Swift 6" rule.
        nonisolated(unsafe) private(set) var set: [(agent: String, instruction: String)] = []
        nonisolated(unsafe) private(set) var cancelled: [String] = []

        init(_ answer: WearerFollowupAcknowledgment) { self.answer = answer }

        func setFollowup(
            agent: String, instruction: String
        ) async -> WearerFollowupAcknowledgment {
            set.append((agent, instruction))
            return answer
        }

        func cancelFollowup(agent: String) async -> WearerFollowupAcknowledgment {
            cancelled.append(agent)
            return answer
        }
    }

    private func makeProvider(
        _ backend: ToolBackend,
        book: Book?,
        loop: (any WearerTaskStarting)? = nil,
        answerer: (@MainActor (String, String?) async -> WorkQuestionOutcome)? = nil,
        sink: RecordingSink = RecordingSink()
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            intentSource: .modelToolCalls,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            answerWorkQuestion: answerer,
            startWearerTask: loop,
            followups: book,
            // Bounded rather than the shipped sixty seconds: an unbounded sleep left running
            // in-process stalls whichever test runs next.
            idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) },
            diagnosticSink: sink
        )
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func call(
        _ name: String, _ arguments: String, id: String = "call_1"
    ) -> VoiceBackendEvent {
        .toolCall(VoiceToolCall(callID: id, name: name, argumentsJSON: arguments))
    }

    // MARK: - Declaration

    func testThePairIsDeclaredOnlyWhenABookIsComposed() async {
        let withBook = ToolBackend()
        _ = makeProvider(withBook, book: Book(.noted(spoken: "ok")))
        XCTAssertEqual(withBook.declaredTools, [[
            "approve", "deny", "select_item", "queue_instruction", "query_status",
            "set_followup", "cancel_followup",
        ]])

        let without = ToolBackend()
        _ = makeProvider(without, book: nil)
        XCTAssertEqual(without.declaredTools, [[
            "approve", "deny", "select_item", "queue_instruction", "query_status",
        ]])
    }

    /// They move together, always. A composition where a follow-up can be armed and not
    /// called off is worse than one with no follow-ups at all.
    func testArmingAndClearingAreNeverSplitApart() async {
        for declared in [true, false] {
            let names = VoiceIntentTools.declarations(includingAskAboutWork: false,
                                                      includingFollowups: declared)
                .map(\.name)
            XCTAssertEqual(names.contains("set_followup"), declared, "\(names)")
            XCTAssertEqual(names.contains("cancel_followup"), declared, "\(names)")
        }
    }

    /// The third gate is independent of the other two: a run may have a loop and no book, a
    /// book and no loop, or all of it.
    func testTheThreeConditionalGatesAreIndependent() async {
        final class Loop: WearerTaskStarting, @unchecked Sendable {
            func startTask(goal: String) async -> WearerTaskStart { .accepted(spoken: "ok") }
        }
        let everything = ToolBackend()
        _ = makeProvider(everything, book: Book(.noted(spoken: "ok")), loop: Loop(),
                         answerer: { _, _ in .answered("x") })
        XCTAssertEqual(everything.declaredTools, [[
            "approve", "deny", "select_item", "queue_instruction", "query_status",
            "ask_about_work", "start_task", "set_followup", "cancel_followup",
        ]])

        let loopOnly = ToolBackend()
        _ = makeProvider(loopOnly, book: nil, loop: Loop())
        XCTAssertEqual(loopOnly.declaredTools.first?.contains("start_task"), true)
        XCTAssertEqual(loopOnly.declaredTools.first?.contains("set_followup"), false)

        let bookOnly = ToolBackend()
        _ = makeProvider(bookOnly, book: Book(.noted(spoken: "ok")))
        XCTAssertEqual(bookOnly.declaredTools.first?.contains("start_task"), false)
        XCTAssertEqual(bookOnly.declaredTools.first?.contains("set_followup"), true)
    }

    /// A call where the pair was never declared is the tool protocol being wrong, not a book
    /// that quietly did nothing. The wearer must never be left believing a promise is armed.
    func testAFollowupWhereTheToolWasNeverDeclaredIsAProtocolFailure() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, book: nil, sink: sink)
        var failures: [String] = []
        provider.onIntentPipelineFailed = { failures.append($0) }

        provider.start { _ in }
        await settle()
        backend.emit(call("set_followup",
                          #"{"agent":"Claude Code","instruction":"rerun the tests"}"#))
        await settle()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(backend.toolResults.count, 1, "the peer must not be left parked")
        XCTAssertTrue(backend.scriptedSpeech.isEmpty)
        XCTAssertTrue(sink.names.contains("tool.protocol_failed"))
    }

    // MARK: - The round trip

    /// The announce wording, end to end. This is the sentence the plan's announce-on-create
    /// rule produces, and the provider speaks it word for word — it composes none of it.
    func testAFollowupIsNotedAndTheAcknowledgmentIsSpokenVerbatim() async {
        let backend = ToolBackend()
        let noted = "After Claude Code finishes: rerun the tests — noted."
        let book = Book(.noted(spoken: noted))
        let sink = RecordingSink()
        let provider = makeProvider(backend, book: book, sink: sink)

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        backend.emit(call("set_followup",
                          #"{"agent":"Claude Code","instruction":"rerun the tests"}"#))
        await settle()
        backend.emit(.responseCompleted)
        await settle()

        XCTAssertEqual(book.set.map(\.agent), ["Claude Code"])
        XCTAssertEqual(book.set.map(\.instruction), ["rerun the tests"])
        XCTAssertEqual(backend.scriptedSpeech, [noted])
        XCTAssertEqual(backend.toolResults.count, 1)
        XCTAssertTrue(sink.names.contains("tool.set_followup_requested"), "\(sink.names)")
        XCTAssertTrue(sink.names.contains("followup.noted"), "\(sink.names)")
    }

    /// A replacement is announced as one, and the model's copy has to say so too: a model
    /// that thought it had armed two would offer to cancel one that no longer exists.
    func testAReplacementIsSpokenAndTheModelIsToldThereIsOnlyEverOne() async {
        let backend = ToolBackend()
        let spoken = "Instead of the last one — after Claude Code finishes: just tell me "
            + "what broke — noted."
        let provider = makeProvider(backend, book: Book(.replaced(spoken: spoken)))

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call("set_followup",
                          #"{"agent":"Claude Code","instruction":"just tell me what broke"}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, [spoken])
        let output = backend.toolResults.first?.output ?? ""
        XCTAssertTrue(output.contains("only ever one per agent"), output)
        XCTAssertTrue(output.contains("Say nothing further"), output)
    }

    func testCancellingIsSpokenVerbatimAndReachesTheBook() async {
        let backend = ToolBackend()
        let book = Book(.dropped(spoken: "Dropped the follow-up on Claude Code."))
        let provider = makeProvider(backend, book: book)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call("cancel_followup", #"{"agent":"Claude Code"}"#))
        await settle()

        XCTAssertEqual(book.cancelled, ["Claude Code"])
        XCTAssertEqual(backend.scriptedSpeech, ["Dropped the follow-up on Claude Code."])
        XCTAssertTrue(book.set.isEmpty)
    }

    /// Nothing to drop is still spoken. A wearer who says "never mind" into a quiet room and
    /// hears nothing cannot tell that from TapQ being broken.
    func testNothingPendingIsStillSaidOutLoud() async {
        let backend = ToolBackend()
        let provider = makeProvider(
            backend, book: Book(.nothingPending(spoken: "There's no follow-up on Codex."))
        )

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call("cancel_followup", #"{"agent":"Codex"}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, ["There's no follow-up on Codex."])
    }

    /// The model's record is not the wearer's sentence, and it has to stop the model
    /// narrating a boundary it will never see: nothing follows `sendToolResult`.
    func testTheModelIsToldNothingHappensUntilTheBoundaryAndToSayNothingFurther() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, book: Book(.noted(spoken: "noted.")))

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call("set_followup", #"{"agent":"Codex","instruction":"tell me"}"#))
        await settle()

        let output = backend.toolResults.first?.output ?? ""
        XCTAssertTrue(output.contains("Nothing happens until that agent's next run finishes"),
                      output)
        XCTAssertTrue(output.contains("it happens once"), output)
        XCTAssertTrue(output.contains("Say nothing further"), output)
        XCTAssertNotEqual(output, "noted.")
    }

    /// Nothing is resolved. The approval the wearer was read is still open afterwards, and a
    /// follow-up needs no window for the same reason a task does not.
    func testNotingAFollowupLeavesTheWindowExactlyAsItFoundIt() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, book: Book(.noted(spoken: "noted.")))
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()
        provider.endActiveTurn()
        backend.emit(call("set_followup", #"{"agent":"Codex","instruction":"tell me"}"#))
        await settle()

        XCTAssertEqual(delivered, [], "noting a follow-up must resolve nothing")
        XCTAssertTrue(provider.isWindowOpenForTesting)
    }

    // MARK: - Bad arguments

    /// An unnamed agent is a complete request TapQ cannot arm, not a mis-heard sentence — so
    /// it asks which agent rather than picking whichever happens to be live. A follow-up on
    /// the wrong agent waits forever and fires never.
    func testAFollowupWithNoAgentAsksWhichOneRatherThanGuessing() async {
        let backend = ToolBackend()
        let book = Book(.noted(spoken: "should not be reached"))
        let provider = makeProvider(backend, book: book)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call("set_followup", #"{"agent":"  ","instruction":"rerun the tests"}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, [VoiceIntentTools.unaddressedFollowupNotice])
        XCTAssertTrue(book.set.isEmpty)
        XCTAssertEqual(backend.toolResults.count, 1, "the peer is still answered")
    }

    func testAnEmptySentenceIsTheOrdinarySayItAgain() async {
        let backend = ToolBackend()
        let book = Book(.noted(spoken: "should not be reached"))
        let provider = makeProvider(backend, book: book)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call("set_followup", #"{"agent":"Codex","instruction":" \n "}"#))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, [VoiceIntentTools.emptyInstructionNotice])
        XCTAssertEqual(VoiceIntentTools.emptyFollowupNotice,
                       VoiceIntentTools.emptyInstructionNotice)
        XCTAssertTrue(book.set.isEmpty)
    }

    func testUnreadableArgumentsAreAProtocolFailure() async {
        let backend = ToolBackend()
        let provider = makeProvider(backend, book: Book(.noted(spoken: "ok")))
        var failures: [String] = []
        provider.onIntentPipelineFailed = { failures.append($0) }

        provider.start { _ in }
        await settle()
        backend.emit(call("set_followup", "{not json"))
        await settle()
        backend.emit(call("set_followup", #"{"agent":"Codex"}"#, id: "call_2"))
        await settle()
        backend.emit(call("cancel_followup", "{}", id: "call_3"))
        await settle()

        XCTAssertEqual(failures.count, 3, "a missing required field is not a request")
        XCTAssertEqual(backend.toolResults.count, 3)
    }

    // MARK: - Diagnostics

    /// The agent's name is the roster's own word for it and is logged. The instruction is the
    /// wearer's own words, and the log this provider writes has never held one.
    func testTheAgentIsLoggedAndTheSentenceIsNot() async {
        let backend = ToolBackend()
        let sink = RecordingSink()
        let secret = "push the release key to the staging box"
        let provider = makeProvider(backend, book: Book(.noted(spoken: "noted.")), sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        backend.emit(call("set_followup",
                          #"{"agent":"Claude Code","instruction":"\#(secret)"}"#))
        await settle()

        let requested = sink.events.first { $0.name == "tool.set_followup_requested" }
        XCTAssertEqual(requested?.fields["agent"], "Claude Code")
        XCTAssertEqual(requested?.fields["length"], "\(secret.count)")
        for event in sink.events {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("staging box"),
                               "\(event.name) put the wearer's sentence in the log")
            }
        }
    }

    // MARK: - The reflex tier is untouched

    func testApproveStillResolvesTheWindowDirectlyWithABookComposed() async {
        let backend = ToolBackend()
        let book = Book(.noted(spoken: "should not be reached"))
        let provider = makeProvider(backend, book: book)
        var delivered: [VoiceCommand] = []

        provider.start { delivered.append($0) }
        await settle()
        backend.emit(.toolCall(VoiceToolCall(callID: "c1", name: "approve", argumentsJSON: "")))
        await settle()

        XCTAssertEqual(delivered, [.yes])
        XCTAssertTrue(book.set.isEmpty)
    }

    // MARK: - The declarations' own words

    /// The description is the only place the boundary between a follow-up and a task can be
    /// drawn, and it has to say the three things a wrong model gets wrong: it fires once, it
    /// is not a way to watch, and nothing happens now.
    func testTheDescriptionSaysItFiresOnceIsNotAWatchAndDoesNothingNow() async {
        let tool = VoiceIntentTools.setFollowupDeclaration
        XCTAssertEqual(tool.name, "set_followup")
        XCTAssertTrue(tool.description.contains("acts on it once"), tool.description)
        XCTAssertTrue(tool.description.contains("not a way to watch something continuously"),
                      tool.description)
        XCTAssertTrue(tool.description.contains("Nothing happens now"), tool.description)
        XCTAssertTrue(tool.description.contains("replaces it"),
                      "one per agent has to be stated")
        XCTAssertTrue(tool.description.lowercased().contains("authorizes nothing"),
                      "noting a follow-up must not read like an approval")

        let byName = Dictionary(uniqueKeysWithValues: tool.parameters.map { ($0.name, $0) })
        XCTAssertEqual(byName["agent"]?.required, true, "a follow-up needs something to wait "
            + "for; the name is never inferred")
        XCTAssertEqual(byName["instruction"]?.required, true)
        XCTAssertEqual(tool.parameters.count, 2)
    }

    /// It names no conditional tool, for the reason `start_task`'s description names none: a
    /// tool pointed at by name may be absent from a session that has this one, and a call for
    /// an undeclared name breaks the voice channel. The boundary is drawn by behavior.
    func testTheDescriptionsNameNoToolThatMightNotBeDeclared() async {
        for tool in [VoiceIntentTools.setFollowupDeclaration,
                     VoiceIntentTools.cancelFollowupDeclaration] {
            XCTAssertFalse(tool.description.contains("start_task"), tool.description)
            XCTAssertFalse(tool.description.contains("ask_about_work"), tool.description)
            XCTAssertFalse(tool.description.contains("set_followup"),
                           "even its own name is a wire name the wearer never says")
        }
        // The when/after boundary is what the wearer actually said, so that is what the model
        // is asked to route on.
        XCTAssertTrue(VoiceIntentTools.setFollowupDeclaration.description
            .contains("said *when* or *after* something finishes"))
    }

    /// The cancel tool says what it does *not* do, because "drop that" is the sort of thing a
    /// wearer might mean about the agent rather than about TapQ's memory of it.
    func testTheCancelDescriptionSaysItNeverStopsTheAgent() async {
        let tool = VoiceIntentTools.cancelFollowupDeclaration
        XCTAssertEqual(tool.name, "cancel_followup")
        XCTAssertTrue(tool.description.contains("never stops or interrupts the agent itself"),
                      tool.description)
        XCTAssertEqual(tool.parameters.map(\.name), ["agent"])
        XCTAssertEqual(tool.parameters.first?.required, true)
    }

    /// The five ratified actions are unchanged by the eighth and ninth: nothing renamed,
    /// nothing reordered, and the tool that could end a session still does not exist.
    func testTheFiveRatifiedToolsAreUntouchedAndNothingEndsTheSession() async {
        XCTAssertEqual(VoiceIntentTools.declarations.map(\.name),
                       ["approve", "deny", "select_item", "queue_instruction", "query_status"])
        let all = VoiceIntentTools.declarations(includingAskAboutWork: true,
                                                includingStartTask: true,
                                                includingFollowups: true)
        XCTAssertEqual(all.map(\.name), [
            "approve", "deny", "select_item", "queue_instruction", "query_status",
            "ask_about_work", "start_task", "set_followup", "cancel_followup",
        ])
    }

    // MARK: - Resolution, in isolation

    func testResolutionEnumeratedWithoutAProvider() async {
        func resolve(_ name: String, _ arguments: String, declared: Bool = true,
                     windowOpen: Bool = true) -> VoiceIntentTools.Resolution {
            VoiceIntentTools.resolve(
                VoiceToolCall(callID: "c1", name: name, argumentsJSON: arguments),
                windowOpen: windowOpen, followupsDeclared: declared)
        }

        guard case .malformed = resolve("set_followup", #"{"agent":"a","instruction":"b"}"#,
                                        declared: false) else {
            return XCTFail("an undeclared set_followup must be a protocol failure")
        }
        guard case .malformed = resolve("cancel_followup", #"{"agent":"a"}"#, declared: false)
        else {
            return XCTFail("an undeclared cancel_followup must be a protocol failure")
        }
        guard case .malformed = resolve("set_followup", "{not json") else {
            return XCTFail("unreadable arguments must be a protocol failure")
        }
        guard case .refused(_, let unaddressed) = resolve(
            "set_followup", #"{"agent":" ","instruction":"b"}"#
        ) else {
            return XCTFail("a blank agent must be refused, not fatal")
        }
        XCTAssertEqual(unaddressed, VoiceIntentTools.unaddressedFollowupNotice)
        guard case .refused(_, let empty) = resolve(
            "set_followup", #"{"agent":"Codex","instruction":" \n "}"#
        ) else {
            return XCTFail("a blank sentence must be refused, not fatal")
        }
        XCTAssertEqual(empty, VoiceIntentTools.emptyFollowupNotice)
        guard case .setFollowup(let agent, let instruction) = resolve(
            "set_followup", #"{"agent":"  Codex  ","instruction":"  tell me  "}"#
        ) else {
            return XCTFail("a real request must set a follow-up")
        }
        XCTAssertEqual(agent, "Codex")
        XCTAssertEqual(instruction, "tell me")

        // And with nothing listening, which changes none of it: a follow-up resolves nothing
        // now, by construction.
        guard case .setFollowup = resolve("set_followup",
                                          #"{"agent":"Codex","instruction":"tell me"}"#,
                                          windowOpen: false) else {
            return XCTFail("a follow-up needs no open window")
        }
        guard case .cancelFollowup(let dropped) = resolve("cancel_followup",
                                                          #"{"agent":" Codex "}"#,
                                                          windowOpen: false) else {
            return XCTFail("a cancel needs no open window either")
        }
        XCTAssertEqual(dropped, "Codex")
    }

    /// The gate defaults to closed, like the two before it: a caller that forgot the argument
    /// gets the Apple path's answer, not the book's.
    func testTheGateIsClosedByDefault() async {
        guard case .malformed = VoiceIntentTools.resolve(
            VoiceToolCall(callID: "c1", name: "set_followup",
                          argumentsJSON: #"{"agent":"a","instruction":"b"}"#),
            windowOpen: true) else {
            return XCTFail("set_followup must be undeclared unless a composition asked for it")
        }
        XCTAssertEqual(VoiceIntentTools.declarations(includingAskAboutWork: false).map(\.name),
                       ["approve", "deny", "select_item", "queue_instruction", "query_status"])
    }
}
