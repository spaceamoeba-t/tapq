import Foundation
import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The question path end to end, minus the network: transcript on disk → slices → one model
/// call → the sentence TapQ speaks, and the two failure classes that must not be confused
/// with each other.
@MainActor
final class TranscriptQuestionAnswererTests: XCTestCase {
    /// Captures what crossed the boundary to the model, and answers with whatever the test
    /// scripted.
    private final class StubModel: WorkQuestionAnswering, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [WorkQuestionRequest] = []
        private let outcome: Result<String, NarrationFailure>

        init(_ outcome: Result<String, NarrationFailure>) { self.outcome = outcome }

        var seen: [WorkQuestionRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func answer(_ request: WorkQuestionRequest) async throws -> String {
            lock.lock()
            requests.append(request)
            lock.unlock()
            return try outcome.get()
        }
    }

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

    private var directory: URL!
    private var path: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-answer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("session.jsonl").path
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func writeTranscript() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"run the test suite"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Executed 12 tests, with 1 failure"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"One test failed: WireProtocolTests"}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func makeStore(attached: Bool = true) throws -> TranscriptStore {
        let store = TranscriptStore()
        if attached {
            try writeTranscript()
            store.attach(session: "s1", path: path)
        }
        return store
    }

    // MARK: - The answer

    /// The model's words are the wearer's answer, unedited. Nothing here summarizes a
    /// summary: the model was asked for speech and this is the speech.
    func testTheAnswerIsTheModelsOwnWords() async throws {
        let model = StubModel(.success("One test failed, WireProtocolTests."))
        let answerer = TranscriptQuestionAnswerer(store: try makeStore(), model: model)

        let outcome = await answerer.answer(question: "what did the tests say?",
                                            agentDisplayName: "Claude Code")

        XCTAssertEqual(outcome, .answered("One test failed, WireProtocolTests."))
    }

    /// What crosses to the provider: the wearer's question as they asked it, the agent by
    /// display name only, and the history. No session identifier — the wearer never hears
    /// one and the model has no use for one.
    func testTheModelIsGivenTheQuestionTheSlicesAndNothingElse() async throws {
        let model = StubModel(.success("ok"))
        let answerer = TranscriptQuestionAnswerer(store: try makeStore(), model: model)

        _ = await answerer.answer(question: "did the tests pass?",
                                  agentDisplayName: "Claude Code")

        let request = try XCTUnwrap(model.seen.first)
        XCTAssertEqual(request.question, "did the tests pass?")
        XCTAssertEqual(request.agentDisplayName, "Claude Code")
        XCTAssertEqual(request.slices.count, 4)
        let rendered = WorkAnswerContract.input(for: request)
        XCTAssertTrue(rendered.contains("Executed 12 tests, with 1 failure"), rendered)
        XCTAssertTrue(rendered.contains("did the tests pass?"), rendered)
        XCTAssertFalse(rendered.contains("s1"), "a session identifier reached the model")
    }

    /// Tool input and tool output are exactly what a question about the work is answered
    /// from, and under a cloud backend TapQ may read them. This is the scoped exemption
    /// stated as a test, so a later "tighten the redaction" edit has to face it directly.
    func testToolInputAndOutputReachTheAnswerModel() async throws {
        let model = StubModel(.success("ok"))
        let answerer = TranscriptQuestionAnswerer(store: try makeStore(), model: model)

        _ = await answerer.answer(question: "what command did you run?", agentDisplayName: nil)

        let rendered = WorkAnswerContract.input(for: try XCTUnwrap(model.seen.first))
        XCTAssertTrue(rendered.contains("swift test"), rendered)
        XCTAssertTrue(rendered.contains("tool: Bash"), rendered)
    }

    /// The in-memory tail is bounded, so a question about something older than it would
    /// otherwise be unanswerable. When the tail comes back saturated the store is asked to
    /// go back to the file — which it can, because the agent's own transcript is the store
    /// and TapQ kept no copy of it.
    func testHistoryOlderThanTheTailIsRereadFromDisk() async throws {
        let lines = (1...40).map {
            #"{"type":"user","message":{"role":"user","content":"line \#($0)"}}"#
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: URL(fileURLWithPath: path), options: .atomic)
        let store = TranscriptStore(tailEntryLimit: 5)
        store.attach(session: "s1", path: path)
        let model = StubModel(.success("ok"))
        let answerer = TranscriptQuestionAnswerer(store: store, model: model)

        _ = await answerer.answer(question: "what happened at line 1?", agentDisplayName: nil)

        let request = try XCTUnwrap(model.seen.first)
        XCTAssertEqual(request.slices.count, 40,
                       "the answer was composed from the bounded tail alone")
    }

    // MARK: - Unreadable transcript: loud, but alive

    /// No transcript is not a broken voice pipe. The wearer is told out loud, the model is
    /// never called, and the session lives.
    func testAnUnattachedSessionIsSpokenRatherThanBroken() async throws {
        let model = StubModel(.success("should not be reached"))
        let answerer = TranscriptQuestionAnswerer(store: try makeStore(attached: false),
                                                  model: model)

        let outcome = await answerer.answer(question: "what did you do?",
                                            agentDisplayName: nil)

        XCTAssertEqual(outcome, .unavailable(TranscriptQuestionAnswerer.notAttachedNotice))
        XCTAssertTrue(model.seen.isEmpty, "no cloud call may be made with nothing to send")
    }

    func testAMissingTranscriptFileIsSpokenRatherThanBroken() async throws {
        let store = TranscriptStore()
        store.attach(session: "s1", path: directory.appendingPathComponent("gone.jsonl").path)
        let model = StubModel(.success("should not be reached"))
        let answerer = TranscriptQuestionAnswerer(store: store, model: model)

        let outcome = await answerer.answer(question: "what did you do?",
                                            agentDisplayName: nil)

        XCTAssertEqual(outcome, .unavailable(TranscriptQuestionAnswerer.unreadableNotice))
        XCTAssertTrue(model.seen.isEmpty)
    }

    /// The three notices are different sentences, because "I don't know where your session
    /// is", "I can't open it", and "there's nothing in it yet" are three different things
    /// for someone who cannot look at a screen.
    func testTheUnavailableNoticesAreDistinct() async throws {
        let notices = Set([
            TranscriptQuestionAnswerer.notAttachedNotice,
            TranscriptQuestionAnswerer.unreadableNotice,
            TranscriptQuestionAnswerer.emptyNotice,
        ])
        XCTAssertEqual(notices.count, 3)
    }

    // MARK: - Cloud failure: break, never a half-answer

    /// The same model family and endpoint as narration, so the same posture. Notably there
    /// is no fallback that assembles something out of the slices TapQ already had in hand:
    /// that would be TapQ answering a question about the wearer's work by itself.
    func testACloudFailureIsReportedAsAFailure() async throws {
        for failure in [NarrationFailure.timedOut, .http(status: 500),
                        .malformedResponse, .transport("send failed")] {
            let model = StubModel(.failure(failure))
            let answerer = TranscriptQuestionAnswerer(store: try makeStore(), model: model)

            let outcome = await answerer.answer(question: "what did the tests say?",
                                                agentDisplayName: nil)

            guard case .failed(let reason) = outcome else {
                XCTFail("\(failure) did not produce a failure outcome")
                continue
            }
            XCTAssertEqual(reason, failure.reason)
        }
    }

    // MARK: - Diagnostics

    /// Lengths and counts, never content, never the key. The rule is checked by looking at
    /// every field of every event rather than at the ones this test expects.
    func testDiagnosticsCarryNoQuestionAndNoTranscriptContent() async throws {
        let sink = RecordingSink()
        let model = StubModel(.success("One test failed."))
        let answerer = TranscriptQuestionAnswerer(
            store: try makeStore(), model: model, diagnosticSink: sink
        )

        _ = await answerer.answer(question: "what did the tests say?",
                                  agentDisplayName: "Claude Code")

        XCTAssertTrue(sink.names.contains("ask.requested"), "\(sink.names)")
        XCTAssertTrue(sink.names.contains("ask.answered"), "\(sink.names)")
        let answered = try XCTUnwrap(sink.events.last { $0.name == "ask.answered" })
        XCTAssertEqual(answered.fields["slices"], "4")
        XCTAssertNotNil(answered.fields["latency_ms"])
        for event in sink.events {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("what did the tests"), "a question was logged")
                XCTAssertFalse(value.contains("Executed 12 tests"), "transcript content logged")
                XCTAssertFalse(value.contains("swift test"), "transcript content was logged")
            }
        }
    }

    /// A question that arrives empty is answered as "nothing legible", not sent to the
    /// model. The provider refuses an empty one before this, so this is the second guard.
    func testAnEmptyQuestionIsNeverSentToTheModel() async throws {
        let model = StubModel(.success("should not be reached"))
        let answerer = TranscriptQuestionAnswerer(store: try makeStore(), model: model)

        let outcome = await answerer.answer(question: "   ", agentDisplayName: nil)

        XCTAssertEqual(outcome, .unavailable(TranscriptQuestionAnswerer.emptyNotice))
        XCTAssertTrue(model.seen.isEmpty)
    }

    // MARK: - The contract

    /// The prompt is the only thing standing between "read me the output" and reading a key
    /// out loud, so its four rules are pinned. Best effort, and documented as such.
    func testTheAnswerPromptStatesItsFourRules() async throws {
        let instructions = WorkAnswerContract.instructions.lowercased()
        XCTAssertTrue(instructions.contains("only from the history"))
        XCTAssertTrue(instructions.contains("credential"))
        XCTAssertTrue(instructions.contains("quote technical tokens exactly"))
        XCTAssertTrue(instructions.contains("say so plainly"))
    }

    /// Strict structured output: TapQ speaks the field verbatim, so a free-text completion
    /// that drifted into prose would be read out as prose.
    func testTheAnswerSchemaIsStrictAndSingleFielded() async throws {
        XCTAssertEqual(WorkAnswerContract.outputSchema["required"] as? [String], ["answer"])
        XCTAssertEqual(WorkAnswerContract.outputSchema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(try WorkAnswerContract.decode(#"{"answer":"Twelve tests passed."}"#),
                       "Twelve tests passed.")
    }

    /// A spoken line has no use for newlines, and an answer that normalized to nothing is a
    /// failure rather than a sentence of silence.
    func testAnEmptyOrUnreadableAnswerIsRejected() async throws {
        XCTAssertThrowsError(try WorkAnswerContract.decode(#"{"answer":"   "}"#))
        XCTAssertThrowsError(try WorkAnswerContract.decode("not json"))
        XCTAssertEqual(try WorkAnswerContract.decode(#"{"answer":"one\ntwo"}"#), "one two")
    }
}

/// Which parts of a long session are handed to the model, and what is reported about the
/// parts that are not.
final class TranscriptSliceSelectionTests: XCTestCase {
    private func entry(_ text: String) -> TranscriptEntry {
        TranscriptEntry(role: .assistant, text: text)
    }

    /// The newest entries are always taken, whatever the question is about: almost every
    /// question a wearer asks is about what just happened.
    func testTheNewestEntriesAreAlwaysSelected() {
        let entries = (1...100).map { entry("line \($0)") }
        let result = TranscriptSliceSelection.select(
            entries: entries, question: "nothing matches this at all", recencyFloor: 5
        )

        XCTAssertEqual(result.slices.map(\.index), [96, 97, 98, 99, 100])
        XCTAssertEqual(result.droppedEntries, 95)
        XCTAssertGreaterThan(result.droppedCharacters, 0)
    }

    /// And then relevance reaches back past them, which is what makes "what did you decide
    /// about the migration?" answerable after twenty lines of something else.
    func testRelevantOlderEntriesAreReachedAfterTheRecentOnes() {
        var entries = [entry("we decided to postpone the migration")]
        entries.append(contentsOf: (1...10).map { entry("unrelated line \($0)") })
        let result = TranscriptSliceSelection.select(
            entries: entries, question: "what did you decide about the migration?",
            recencyFloor: 3
        )

        XCTAssertTrue(result.slices.contains { $0.index == 1 },
                      "the relevant older entry was not reached")
        XCTAssertEqual(result.slices.map(\.index), result.slices.map(\.index).sorted(),
                       "slices are handed over in the order they happened")
    }

    /// The budget is a cap on the answer prompt, not a suggestion.
    func testTheCharacterBudgetIsRespected() {
        let entries = (1...50).map { _ in entry(String(repeating: "z", count: 1_000)) }
        let result = TranscriptSliceSelection.select(
            entries: entries, question: "anything", budget: 5_000, recencyFloor: 50
        )

        let total = result.slices.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(total, 5_000)
        XCTAssertGreaterThan(result.droppedEntries, 0)
    }

    /// One enormous tool output must not evict everything around it: it is capped, the cut
    /// is reported inside the text so the model does not mistake it for the end, and the
    /// characters removed are counted as dropped.
    func testOneHugeEntryIsCappedRatherThanAllowedToEvictTheRest() {
        let entries = [entry(String(repeating: "q", count: 50_000))] + (1...5).map {
            entry("later line \($0)")
        }
        let result = TranscriptSliceSelection.select(
            entries: entries, question: "q", recencyFloor: 6, entryCap: 1_000
        )

        XCTAssertEqual(result.slices.count, 6, "every entry still made it in")
        let first = try? XCTUnwrap(result.slices.first)
        XCTAssertTrue(first?.text.contains("characters not shown") ?? false)
        XCTAssertGreaterThan(result.droppedCharacters, 40_000)
    }

    /// Nothing to answer from is not a crash and not an empty prompt: the caller turns it
    /// into the spoken "there is nothing there yet".
    func testNoEntriesSelectsNothing() {
        let result = TranscriptSliceSelection.select(entries: [], question: "anything")
        XCTAssertTrue(result.slices.isEmpty)
        XCTAssertEqual(result.droppedEntries, 0)
    }

    /// Short technical words are exactly what a question hangs on, so the filter is a length
    /// floor rather than a dictionary of "important" words.
    func testShortTechnicalWordsSurviveKeywordExtraction() {
        let keywords = TranscriptSliceSelection.keywords(in: "did npm ci pass for the CLI?")
        XCTAssertTrue(keywords.contains("npm"))
        XCTAssertTrue(keywords.contains("cli"))
        XCTAssertFalse(keywords.contains("the"))
        XCTAssertFalse(keywords.contains("did"))
    }
}
