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

    func testAnAnswerCombinesTheTranscriptWithTapQsOwnMemory() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.transcriptAnswer = .ok("Session history: 3 tests failed in VoiceSuite.")
        surfaces.memoryAnswer = .ok("The wearer asked TapQ to watch VoiceSuite.")
        let sink = TaskDiagnosticSink()
        let (loop, reasoner) = makeLoop([
            .decide(.readTranscript(agent: "Claude Code", query: "tests")),
            .decide(.searchMemory(query: "VoiceSuite")),
            .decide(.finish(summary: "Three failed in VoiceSuite — the suite you asked me "
                + "to watch.")),
        ], surfaces: surfaces, sink: sink)

        let outcome = await loop.answerWorkQuestion(
            question: "what did the tests say?", agentDisplayName: "Claude Code"
        )

        XCTAssertEqual(outcome, .answered(
            "Three failed in VoiceSuite — the suite you asked me to watch."
        ))
        XCTAssertEqual(surfaces.transcriptQueries.map(\.query), ["tests"])
        XCTAssertEqual(surfaces.memoryQueries, ["VoiceSuite"])
        // The lane never speaks: the provider speaks the answer, exactly as it did in M1.
        XCTAssertTrue(surfaces.spoken.isEmpty, "\(surfaces.spoken)")
        // The named agent reaches the model in the prompt, as it did through
        // `WorkAnswerContract.input`.
        XCTAssertEqual(reasoner.requests.first?.agentDisplayName, "Claude Code")
        XCTAssertTrue(
            WearerTaskContract.input(for: reasoner.requests[0]).contains("Agent: Claude Code")
        )
        XCTAssertEqual(sink.first("task.question_answered")?.fields["steps"], "3")
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

    // MARK: - The two failure classes stay apart

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
            case .task:
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
