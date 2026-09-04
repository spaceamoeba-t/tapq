import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// `ask_about_work`, folded into the loop (`docs/TAPQ_AGENT_PLAN.md`, Pillar B's one
/// revision at M2).
///
/// The point of this suite is that the *wearer-facing* behavior did not move. M1's three
/// outcomes still mean what they meant, the answer is still the model's words spoken
/// verbatim, and the two failure classes are still apart: a file that will not open is
/// spoken and survivable, a cloud call that fails says nothing and breaks the run's voice.
/// What changed is underneath — the lane fetches its own evidence and may combine an agent's
/// transcript with TapQ's own memory — plus one bound the fold-in cost, pinned below.
@MainActor
final class WearerTaskQuestionLaneTests: XCTestCase {
    private func makeLoop(
        _ script: [ScriptedTaskReasoner.Turn],
        surfaces: RecordingTaskSurfaces,
        sink: TaskDiagnosticSink = TaskDiagnosticSink(),
        questionStepCap: Int = WearerTaskLoop.questionStepCap
    ) -> (WearerTaskLoop, ScriptedTaskReasoner) {
        // A tripwire rather than a polite default: every test below scripts exactly as many
        // turns as its cap allows, so reaching this means the lane asked for a turn it had
        // no budget for.
        let reasoner = ScriptedTaskReasoner(script, whenExhausted: .fail(.malformedResponse))
        let loop = WearerTaskLoop(
            model: reasoner,
            surfaces: surfaces.make(),
            questionStepCap: questionStepCap,
            diagnosticSink: sink
        )
        return (loop, reasoner)
    }

    // MARK: - Answered

    /// The typical ask, and the whole of the 2026-08-30 fix: both lookups are already in the
    /// model's hands on its first turn, so the answer costs ONE cloud call rather than the
    /// two it was measured at live (~1.1 s to decide to read, then ~1.2–3.8 s to answer).
    func testAnAnswerCombinesTheTranscriptWithTapQsOwnMemoryInOneModelCall() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.transcriptAnswer = .ok(
            "Session history: 3 tests failed in VoiceSuite.", itemCount: 4
        )
        surfaces.memoryAnswer = .ok(
            "The wearer asked TapQ to watch VoiceSuite.", itemCount: 2
        )
        let sink = TaskDiagnosticSink()
        let (loop, reasoner) = makeLoop([
            .decide(.finish(summary: "Three failed in VoiceSuite — the suite you asked me "
                + "to watch.")),
        ], surfaces: surfaces, sink: sink)

        let outcome = await loop.answerWorkQuestion(
            question: "what did the tests say?", agentDisplayName: "Claude Code"
        )

        XCTAssertEqual(outcome, .answered(
            "Three failed in VoiceSuite — the suite you asked me to watch."
        ))
        XCTAssertEqual(reasoner.requests.count, 1, "the typical question is one cloud call")

        // Both lookups ran, before the model, over the wearer's own question — and through
        // the same two surfaces the model would have called, so nothing can drift.
        XCTAssertEqual(surfaces.transcriptQueries.map(\.agent), ["Claude Code"])
        XCTAssertEqual(surfaces.transcriptQueries.map(\.query), ["what did the tests say?"])
        XCTAssertEqual(surfaces.memoryQueries, ["what did the tests say?"])

        // And both rode the first turn, where the model could read them.
        let first = try? XCTUnwrap(reasoner.requests.first)
        XCTAssertEqual(first?.evidence.map(\.tool), ["read_transcript", "search_memory"])
        let input = WearerTaskContract.input(for: reasoner.requests[0])
        XCTAssertTrue(input.contains("looked these up for you before your first turn"), input)
        XCTAssertTrue(input.contains("Session history: 3 tests failed in VoiceSuite."), input)
        XCTAssertTrue(input.contains("The wearer asked TapQ to watch VoiceSuite."), input)
        // Evidence is not history: a model told it had already called a tool it never called
        // is a model that will not call it when it should.
        XCTAssertTrue(input.contains("You have not called any tools yourself yet"), input)

        // The lane never speaks: the provider speaks the answer, exactly as it did in M1.
        XCTAssertTrue(surfaces.spoken.isEmpty, "\(surfaces.spoken)")
        // The named agent reaches the model in the prompt, as it did through
        // `WorkAnswerContract.input`.
        XCTAssertEqual(first?.agentDisplayName, "Claude Code")
        XCTAssertTrue(input.contains("Agent: Claude Code"), input)

        // The latency line, which is how the improvement is read on hardware.
        let answered = sink.first("task.question_answered")
        XCTAssertEqual(answered?.fields["model_calls"], "1")
        XCTAssertEqual(answered?.fields["slices"], "4")
        XCTAssertEqual(answered?.fields["memories"], "2")
        XCTAssertEqual(answered?.fields["steps"], "1")
        XCTAssertNotNil(answered?.fields["latency_ms"])
    }

    /// One call is the typical path, not a cap. Pre-fetched evidence that does not answer the
    /// question leaves the lane's bounds exactly where they were.
    func testEvidenceThatDoesNotAnswerStillBuysAnotherLookupWithinTheBounds() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.transcriptAnswer = .ok("Session history: nothing about the migration.")
        surfaces.memoryAnswer = .ok(WearerMemorySearch.noMatchesText)
        let sink = TaskDiagnosticSink()
        let (loop, reasoner) = makeLoop([
            // The pre-fetch used the wearer's words; the model tries sharper ones.
            .decide(.searchMemory(query: "schema migration Codex")),
            .decide(.finish(summary: "You told Codex to run the schema migration on Tuesday.")),
        ], surfaces: surfaces, sink: sink)

        let outcome = await loop.answerWorkQuestion(
            question: "what did I say about the migration?", agentDisplayName: nil
        )

        XCTAssertEqual(outcome, .answered(
            "You told Codex to run the schema migration on Tuesday."
        ))
        XCTAssertEqual(reasoner.requests.count, 2)
        // The wearer's words first, from the pre-fetch; then the model's sharper ones.
        XCTAssertEqual(surfaces.memoryQueries,
                       ["what did I say about the migration?", "schema migration Codex"])
        // The second turn carries both the evidence and the step the model chose, apart.
        let second = reasoner.requests[1]
        XCTAssertEqual(second.evidence.count, 2)
        XCTAssertEqual(second.steps.map(\.tool), ["search_memory"])
        XCTAssertEqual(sink.first("task.question_answered")?.fields["model_calls"], "2")
    }

    func testTheQuestionLaneDeclaresOnlyItsThreeReadOnlyTools() async throws {
        let names = WearerTaskContract.tools(for: .question)
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["search_memory", "read_transcript", "finish"])

        // Undeclared here means undeclared on the wire, exactly as `ask_about_work` itself
        // is gated: a question that could queue an instruction would be authority the wearer
        // did not hand over.
        for forbidden in ["queue_instruction", "speak", "ask_wearer", "get_status"] {
            XCTAssertThrowsError(try WearerTaskContract.decode(
                name: forbidden, argumentsJSON: "{\"text\":\"x\"}", mode: .question
            ), forbidden)
        }
    }

    func testAnEmptyQuestionIsTheM1EmptyNotice() async {
        let surfaces = RecordingTaskSurfaces()
        let sink = TaskDiagnosticSink()
        let (loop, reasoner) = makeLoop([], surfaces: surfaces, sink: sink)

        let outcome = await loop.answerWorkQuestion(question: "  ", agentDisplayName: nil)

        XCTAssertEqual(outcome, .unavailable(TranscriptQuestionAnswerer.emptyNotice))
        XCTAssertEqual(reasoner.requests.count, 0, "no cloud call for an empty question")
        XCTAssertEqual(sink.first("task.question_unavailable")?.level, .error)
    }

    // MARK: - The two failure classes stay apart, at the pre-fetch too

    /// The pre-fetch is a local read, so a history that will not open there is the same class
    /// it is mid-lane: loud in the log, honest to the model, spoken, and the session lives.
    func testAnUnreadableTranscriptAtPreFetchIsSpokenHonestyNotABreak() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.transcriptAnswer = .localFailure(
            "unreadable",
            tellingModel: "TapQ cannot read that session's history, so there are no "
                + "excerpts. Say so plainly rather than guessing what it contained.",
            saying: TranscriptQuestionAnswerer.unreadableNotice
        )
        let sink = TaskDiagnosticSink()
        var broken: [String] = []
        // The model looks elsewhere and never finishes, which is the worst case: the sentence
        // the wearer hears is the one the pre-fetch carried, not the generic one.
        let (loop, reasoner) = makeLoop([
            .decide(.searchMemory(query: "tests")),
            .decide(.searchMemory(query: "tests again")),
            .decide(.searchMemory(query: "tests once more")),
        ], surfaces: surfaces, sink: sink)
        loop.onLoopBroken = { broken.append($0) }

        let outcome = await loop.answerWorkQuestion(
            question: "what did the tests say?", agentDisplayName: nil
        )

        XCTAssertEqual(outcome, .unavailable(TranscriptQuestionAnswerer.unreadableNotice))
        XCTAssertTrue(broken.isEmpty, "an unreadable file must never break the voice")
        let prefetchFailures = sink.all("task.prefetch_unavailable")
        XCTAssertEqual(prefetchFailures.map { $0.fields["tool"] }, ["read_transcript"])
        XCTAssertEqual(prefetchFailures.first?.level, .error)
        // Told plainly on the first turn, so it could have been honest in its own words.
        XCTAssertTrue(
            WearerTaskContract.input(for: reasoner.requests[0])
                .contains("Say so plainly rather than guessing"),
            WearerTaskContract.input(for: reasoner.requests[0])
        )
    }

    /// A memory store that will not open is loud and survivable, and the lane answers from
    /// the agent's history it does have.
    func testAMemoryFailureAtPreFetchIsLoudAndTheLaneAnswersAnyway() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.transcriptAnswer = .ok("Session history: 385 tests passed.", itemCount: 3)
        surfaces.memoryAnswer = .localFailure(
            "memory unreadable",
            tellingModel: "TapQ cannot read its own record of this conversation.",
            saying: "I can't read my own notes right now."
        )
        let sink = TaskDiagnosticSink()
        var broken: [String] = []
        let (loop, reasoner) = makeLoop([
            .decide(.finish(summary: "All 385 passed.")),
        ], surfaces: surfaces, sink: sink)
        loop.onLoopBroken = { broken.append($0) }

        let outcome = await loop.answerWorkQuestion(
            question: "did the tests pass?", agentDisplayName: nil
        )

        XCTAssertEqual(outcome, .answered("All 385 passed."))
        XCTAssertEqual(reasoner.requests.count, 1, "one half failing does not cost a call")
        XCTAssertTrue(broken.isEmpty)
        let failure = sink.first("task.prefetch_unavailable")
        XCTAssertEqual(failure?.fields["tool"], "search_memory")
        XCTAssertEqual(failure?.level, .error)
        XCTAssertEqual(sink.first("task.question_prefetched")?.fields["memory_ok"], "false")
        XCTAssertEqual(sink.first("task.question_prefetched")?.fields["transcript_ok"], "true")
    }

    /// And a memory failure never becomes the spoken sentence: the wearer asked about the
    /// agent's work, and "I can't read my own notes" answers a question they did not ask.
    func testAMemoryFailureDoesNotBecomeTheSentenceTheWearerHears() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.memoryAnswer = .localFailure(
            "memory unreadable",
            tellingModel: "TapQ cannot read its own record of this conversation.",
            saying: "I can't read my own notes right now."
        )
        let (loop, _) = makeLoop([
            .decide(.readTranscript(agent: nil, query: "tests")),
        ], surfaces: surfaces, questionStepCap: 1)

        let outcome = await loop.answerWorkQuestion(
            question: "did the tests pass?", agentDisplayName: nil
        )

        XCTAssertEqual(outcome, .unavailable(WearerTaskLoop.couldNotAnswerNotice))
    }

    func testAnUnreadableTranscriptIsSpokenAndTheSessionLives() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.transcriptAnswer = .localFailure(
            "unreadable",
            tellingModel: "TapQ cannot read that session's history.",
            saying: TranscriptQuestionAnswerer.unreadableNotice
        )
        let sink = TaskDiagnosticSink()
        var broken: [String] = []
        // The model keeps reaching for a transcript it cannot have and never finishes, which
        // is the worst case: the lane runs out of room with a local problem to report.
        let (loop, _) = makeLoop([
            .decide(.readTranscript(agent: nil, query: "tests")),
            .decide(.readTranscript(agent: nil, query: "tests")),
            .decide(.readTranscript(agent: nil, query: "tests")),
        ], surfaces: surfaces, sink: sink)
        loop.onLoopBroken = { broken.append($0) }

        let outcome = await loop.answerWorkQuestion(
            question: "what did the tests say?", agentDisplayName: nil
        )

        // The M1 sentence, unchanged, and the M1 class: unavailable, not failed.
        XCTAssertEqual(outcome, .unavailable(TranscriptQuestionAnswerer.unreadableNotice))
        XCTAssertTrue(broken.isEmpty, "an unreadable file must never break the voice")
        XCTAssertEqual(sink.first("task.tool_unavailable")?.level, .error)
        XCTAssertEqual(sink.first("task.question_unavailable")?.fields["reason"], "local")
    }

    func testACloudFailureFailsTheQuestionAndSaysNothing() async {
        let surfaces = RecordingTaskSurfaces()
        let sink = TaskDiagnosticSink()
        var broken: [String] = []
        let (loop, _) = makeLoop([.fail(.timedOut)], surfaces: surfaces, sink: sink)
        loop.onLoopBroken = { broken.append($0) }

        let outcome = await loop.answerWorkQuestion(
            question: "what did the tests say?", agentDisplayName: nil
        )

        XCTAssertEqual(outcome, .failed("timeout"))
        XCTAssertTrue(surfaces.spoken.isEmpty)
        // Not `onLoopBroken`: the provider latches a `failed` outcome through
        // `onWorkAnswerFailed`, and reporting the same failure twice would give an operator
        // two lines for one event.
        XCTAssertTrue(broken.isEmpty)
        XCTAssertEqual(sink.first("task.question_failed")?.level, .error)
    }

    // MARK: - The bound the fold-in cost

    func testRunningOutOfStepsSaysSoRatherThanInventingAnAnswer() async {
        let surfaces = RecordingTaskSurfaces()
        let sink = TaskDiagnosticSink()
        let (loop, reasoner) = makeLoop([
            .decide(.searchMemory(query: "one")),
            .decide(.searchMemory(query: "two")),
        ], surfaces: surfaces, sink: sink, questionStepCap: 2)

        let outcome = await loop.answerWorkQuestion(
            question: "what did the tests say?", agentDisplayName: nil
        )

        XCTAssertEqual(outcome, .unavailable(WearerTaskLoop.couldNotAnswerNotice))
        XCTAssertEqual(reasoner.requests.count, 2, "the cap is a cap on model calls")
        XCTAssertEqual(sink.first("task.question_unavailable")?.fields["reason"], "no_finish")
    }

    // MARK: - The lane does not take the task slot

    /// Hangs a task turn forever and answers a question turn from a script, so one loop can
    /// be busy and asked at the same time.
    private final class ModeSplitReasoner: WearerTaskReasoning, @unchecked Sendable {
        private let answer: String

        init(answer: String) { self.answer = answer }

        func decide(_ request: WearerTaskTurnRequest) async throws -> WearerTaskDecision {
            switch request.mode {
            case .task, .followup:
                // Both lanes that take the task slot hang here, so the property under test —
                // that a question is answered while the slot is held — holds however the
                // slot came to be held.
                try? await Task.sleep(for: .seconds(3_600))
                throw NarrationFailure.timedOut
            case .question:
                return .finish(summary: answer)
            }
        }
    }

    func testAQuestionIsAnsweredWhileATaskIsStillRunning() async {
        // M1 answered every question; refusing one because a background task happened to be
        // running would be a regression for no safety gained. The lane resolves nothing,
        // declares three read-only tools, and holds no slot, so `busy` governs `start_task`
        // and nothing else.
        let surfaces = RecordingTaskSurfaces()
        let loop = WearerTaskLoop(
            model: ModeSplitReasoner(answer: "All green."),
            surfaces: surfaces.make()
        )

        _ = loop.begin(goal: "watch the build")
        XCTAssertTrue(loop.isBusy)
        XCTAssertEqual(loop.begin(goal: "something else"),
                       .busy(spoken: WearerTaskLoop.busyNotice))

        let outcome = await loop.answerWorkQuestion(
            question: "how did it go?", agentDisplayName: nil
        )
        XCTAssertEqual(outcome, .answered("All green."))
        XCTAssertTrue(loop.isBusy, "answering a question must not end the running task")

        loop.cancel()
    }
}
