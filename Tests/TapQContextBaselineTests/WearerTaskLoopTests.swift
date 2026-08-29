import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The task lane of TapQ's deliberation loop (`docs/TAPQ_AGENT_PLAN.md`, Pillar C, M2).
///
/// What is pinned here is the set of promises the plan makes out loud: one task at a time,
/// bounded steps, progress spoken only when there is progress, a pause that resumes, and —
/// the load-bearing one — that *every* way a task can end is audible except the two where
/// there is nobody left to hear it.
///
/// Every test method is `async`, including the ones with nothing to await: the Swift 6
/// test-discovery shim on Linux will not register a synchronous method on a `@MainActor`
/// case, and a test that silently does not run is worse than one that fails.
@MainActor
final class WearerTaskLoopTests: XCTestCase {
    private func makeLoop(
        _ script: [ScriptedTaskReasoner.Turn],
        surfaces: RecordingTaskSurfaces,
        sink: TaskDiagnosticSink = TaskDiagnosticSink(),
        stepCap: Int = WearerTaskLoop.taskStepCap
    ) -> (WearerTaskLoop, ScriptedTaskReasoner) {
        let reasoner = ScriptedTaskReasoner(script)
        let loop = WearerTaskLoop(
            model: reasoner,
            surfaces: surfaces.make(),
            stepCap: stepCap,
            diagnosticSink: sink
        )
        return (loop, reasoner)
    }

    // MARK: - The happy path

    func testMultiStepTaskGathersEvidenceThenSpeaksTheSummary() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.memoryAnswer = .ok("The wearer asked TapQ to watch the build.")
        surfaces.transcriptAnswer = .ok("Session history: 385 tests, 0 failures.")
        let sink = TaskDiagnosticSink()
        let (loop, reasoner) = makeLoop([
            .decide(.searchMemory(query: "build")),
            .decide(.readTranscript(agent: "Claude Code", query: "tests")),
            .decide(.finish(summary: "385 tests, no failures.")),
        ], surfaces: surfaces, sink: sink)

        let start = loop.begin(goal: "check whether the tests passed")
        XCTAssertEqual(start, .accepted(spoken: "On it — check whether the tests passed"))
        await awaitIdle(loop)

        XCTAssertEqual(surfaces.memoryQueries, ["build"])
        XCTAssertEqual(surfaces.transcriptQueries.map(\.agent), ["Claude Code"])
        // Only the summary is spoken. The two lookups said nothing, which is the plan's
        // "speaks progress only when it has something to say".
        XCTAssertEqual(surfaces.spoken, ["385 tests, no failures."])

        // Each turn carries what the previous ones found, because the Responses API is
        // called with `store: false` and the rendered history is the loop's whole memory.
        XCTAssertEqual(reasoner.requests.count, 3)
        XCTAssertEqual(reasoner.requests[0].steps.count, 0)
        XCTAssertEqual(reasoner.requests[2].steps.map(\.tool),
                       ["search_memory", "read_transcript"])
        XCTAssertTrue(reasoner.requests[2].steps[1].result.contains("385 tests"))
        XCTAssertEqual(reasoner.requests[0].stepsRemaining, WearerTaskLoop.taskStepCap)

        let finished = sink.first("task.finished")
        XCTAssertEqual(finished?.fields["outcome"], "finished")
        XCTAssertEqual(finished?.fields["steps"], "3")
        XCTAssertEqual(sink.all("task.step").map { $0.fields["tool"] },
                       ["search_memory", "read_transcript", "finish"])
        // Counts and names only: nothing in the log quotes the goal or an excerpt.
        for event in sink.events where event.category == "WearerTask" {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("385 tests"), "\(event.name) leaked a result")
                XCTAssertFalse(value.contains("check whether"), "\(event.name) leaked the goal")
            }
        }
    }

    func testSpeakToolSaysProgressAndTheTaskCarriesOn() async {
        let surfaces = RecordingTaskSurfaces()
        let (loop, _) = makeLoop([
            .decide(.speak("This will take a moment.")),
            .decide(.getStatus),
            .decide(.finish(summary: "Nothing is waiting.")),
        ], surfaces: surfaces)

        _ = loop.begin(goal: "see what is waiting")
        await awaitIdle(loop)

        XCTAssertEqual(surfaces.spoken, ["This will take a moment.", "Nothing is waiting."])
        XCTAssertEqual(surfaces.statusCalls, 1)
    }

    // MARK: - One at a time

    func testASecondGoalIsRefusedOutLoudRatherThanQueued() async {
        let surfaces = RecordingTaskSurfaces()
        let sink = TaskDiagnosticSink()
        let loop = WearerTaskLoop(
            model: HangingTaskReasoner(),
            surfaces: surfaces.make(),
            diagnosticSink: sink
        )

        let first = loop.begin(goal: "watch the build")
        guard case .accepted = first else { return XCTFail("expected the first goal taken") }
        XCTAssertTrue(loop.isBusy)

        let second = loop.begin(goal: "rerun the failing suite")
        XCTAssertEqual(second, .busy(spoken: WearerTaskLoop.busyNotice))
        XCTAssertTrue(sink.names.contains("task.busy"))
        // Not queued anywhere: the second goal left no trace but the refusal.
        XCTAssertEqual(surfaces.recorded.map(\.goal), ["watch the build"])

        loop.cancel()
    }

    func testAnEmptyGoalIsRefusedAndStartsNothing() async {
        let surfaces = RecordingTaskSurfaces()
        let sink = TaskDiagnosticSink()
        let (loop, _) = makeLoop([], surfaces: surfaces, sink: sink)

        XCTAssertEqual(loop.begin(goal: "   "),
                       .busy(spoken: WearerTaskLoop.emptyGoalNotice))
        XCTAssertFalse(loop.isBusy)
        XCTAssertTrue(surfaces.recorded.isEmpty)
        XCTAssertEqual(sink.first("task.rejected")?.fields["reason"], "empty_goal")
    }

    // MARK: - The step cap

    func testHittingTheStepCapSaysSoRatherThanGoingQuiet() async {
        let surfaces = RecordingTaskSurfaces()
        let sink = TaskDiagnosticSink()
        let (loop, _) = makeLoop([
            .decide(.getStatus),
            .decide(.getStatus),
            .decide(.getStatus),
        ], surfaces: surfaces, sink: sink, stepCap: 3)

        _ = loop.begin(goal: "find out what Codex is doing")
        await awaitIdle(loop)

        XCTAssertEqual(surfaces.spoken, [
            WearerTaskLoop.couldNotFinishNotice(goal: "find out what Codex is doing"),
        ])
        XCTAssertEqual(surfaces.spoken.first, "I couldn't finish: find out what Codex is doing")
        XCTAssertEqual(sink.first("task.finished")?.fields["outcome"], "could not finish")
        XCTAssertEqual(surfaces.recorded.last?.outcome, "could not finish")
    }

    func testTheLastTurnIsToldItIsTheLastTurn() async {
        let surfaces = RecordingTaskSurfaces()
        let (loop, reasoner) = makeLoop([
            .decide(.getStatus),
            .decide(.finish(summary: "Nothing is waiting.")),
        ], surfaces: surfaces, stepCap: 2)

        _ = loop.begin(goal: "check the queue")
        await awaitIdle(loop)

        XCTAssertEqual(reasoner.requests.map(\.stepsRemaining), [2, 1])
        let lastInput = WearerTaskContract.input(for: reasoner.requests[1])
        XCTAssertTrue(lastInput.contains("This is your last turn"), lastInput)
    }

    // MARK: - ask_wearer

    func testAskWearerPausesTheLoopAndResumesWithTheAnswer() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.wearerAnswer = .no
        let (loop, reasoner) = makeLoop([
            .decide(.askWearer(question: "Should I have Codex rerun it?")),
            .decide(.finish(summary: "Left it alone, then.")),
        ], surfaces: surfaces)

        _ = loop.begin(goal: "decide what to do about the failure")
        await awaitIdle(loop)

        XCTAssertEqual(surfaces.asked, ["Should I have Codex rerun it?"])
        // The answer comes back as the tool's result, so the next turn reasons from it.
        XCTAssertEqual(reasoner.requests[1].steps.first?.result, "The wearer answered no.")
        XCTAssertEqual(surfaces.spoken, ["Left it alone, then."])
    }

    func testAskWearerWithNoAnswerEndsTheTaskAudibly() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.wearerAnswer = .unanswered
        let sink = TaskDiagnosticSink()
        let (loop, reasoner) = makeLoop([
            .decide(.askWearer(question: "Should I have Codex rerun it?")),
            // Never reached: an unanswered question ends the task where it stands.
            .decide(.finish(summary: "unreachable")),
        ], surfaces: surfaces, sink: sink)

        _ = loop.begin(goal: "decide what to do about the failure")
        await awaitIdle(loop)

        XCTAssertEqual(reasoner.requests.count, 1)
        XCTAssertEqual(surfaces.spoken, [
            WearerTaskLoop.unansweredNotice(goal: "decide what to do about the failure"),
        ])
        XCTAssertTrue(sink.names.contains("task.ask_unanswered"))
        XCTAssertEqual(surfaces.recorded.last?.outcome, "unanswered")
    }

    // MARK: - Failure posture

    func testACloudFailureBreaksTheVoiceAndSaysNothing() async {
        let surfaces = RecordingTaskSurfaces()
        let sink = TaskDiagnosticSink()
        let (loop, _) = makeLoop([
            .decide(.getStatus),
            .fail(.http(status: 503)),
        ], surfaces: surfaces, sink: sink)

        var broken: [String] = []
        loop.onLoopBroken = { broken.append($0) }

        _ = loop.begin(goal: "check the build")
        await awaitIdle(loop)

        XCTAssertEqual(broken, ["http 503"])
        // Deliberately silent: the latch speaks its own notice, and a second sentence from
        // TapQ would be the degraded half-agent the posture forbids.
        XCTAssertTrue(surfaces.spoken.isEmpty, "\(surfaces.spoken)")
        let failed = sink.first("task.model_failed")
        XCTAssertEqual(failed?.level, .error)
        XCTAssertEqual(failed?.fields["reason"], "http 503")
        XCTAssertEqual(sink.first("task.finished")?.fields["outcome"], "broken")
        XCTAssertEqual(surfaces.recorded.last?.outcome, "broken")
    }

    func testALocalFileProblemIsLoudAndTheTaskCarriesOn() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.transcriptAnswer = .localFailure(
            "unreadable",
            tellingModel: "TapQ cannot read that session's history.",
            saying: TranscriptQuestionAnswerer.unreadableNotice
        )
        let sink = TaskDiagnosticSink()
        var broken: [String] = []
        let (loop, reasoner) = makeLoop([
            .decide(.readTranscript(agent: nil, query: "tests")),
            .decide(.finish(summary: "I can't see the session history right now.")),
        ], surfaces: surfaces, sink: sink)
        loop.onLoopBroken = { broken.append($0) }

        _ = loop.begin(goal: "say what the tests did")
        await awaitIdle(loop)

        // Loud.
        let unavailable = sink.first("task.tool_unavailable")
        XCTAssertEqual(unavailable?.level, .error)
        XCTAssertEqual(unavailable?.fields["reason"], "unreadable")
        XCTAssertEqual(unavailable?.fields["tool"], "read_transcript")
        // Honest to the model, so it can be honest to the wearer.
        XCTAssertEqual(reasoner.requests[1].steps.first?.result,
                       "TapQ cannot read that session's history.")
        // Alive: no break, and the wearer hears the model's own sentence.
        XCTAssertTrue(broken.isEmpty)
        XCTAssertEqual(surfaces.spoken, ["I can't see the session history right now."])
        XCTAssertEqual(sink.first("task.finished")?.fields["outcome"], "finished")
    }

    // MARK: - Cancellation

    func testCancellationEndsTheTaskSilentlyAndRecordsIt() async {
        let surfaces = RecordingTaskSurfaces()
        let sink = TaskDiagnosticSink()
        let loop = WearerTaskLoop(
            model: HangingTaskReasoner(),
            surfaces: surfaces.make(),
            diagnosticSink: sink
        )

        _ = loop.begin(goal: "watch the build")
        XCTAssertTrue(loop.isBusy)
        loop.cancel(reason: "runtime shutdown")

        // The slot is free the instant cancel returns, so a runtime tearing down does not
        // wait on a model call it is about to have no use for.
        XCTAssertFalse(loop.isBusy)
        XCTAssertEqual(sink.first("task.canceled")?.fields["reason"], "runtime shutdown")
        // Silent by design: the channel a sentence would go out on is being torn down.
        XCTAssertTrue(surfaces.spoken.isEmpty)
        // The record still gets the start, which is what a wearer asking tomorrow reads.
        XCTAssertEqual(surfaces.recorded.first?.outcome, WearerTaskLoop.startedOutcome)
    }

    func testCancellingBetweenTurnsStopsBeforeTheNextToolRuns() async {
        let surfaces = RecordingTaskSurfaces()
        let reasoner = ScriptedTaskReasoner(
            [.decide(.getStatus)],
            // The second turn hangs, so the test can cancel while it is in flight.
            whenExhausted: .decide(.finish(summary: "never spoken"))
        )
        let loop = WearerTaskLoop(model: reasoner, surfaces: surfaces.make())

        _ = loop.begin(goal: "check the queue")
        // Let the first turn land, then cancel before the loop can speak a summary.
        await Task.yield()
        loop.cancel()
        await awaitIdle(loop)

        XCTAssertFalse(surfaces.spoken.contains("never spoken"))
    }

    // MARK: - The durable record

    func testTheGoalAndItsEndingSurviveARestart() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tapq-task-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WearerConversationStore(directory: directory)
        let surfaces = RecordingTaskSurfaces()
        let reasoner = ScriptedTaskReasoner([.decide(.finish(summary: "All green."))])
        var wired = surfaces.make()
        wired.recordTask = { goal, outcome in
            store.recordTask(goal: goal, outcome: outcome)
        }
        let loop = WearerTaskLoop(model: reasoner, surfaces: wired)

        _ = loop.begin(goal: "tell me whether the tests passed")
        await awaitIdle(loop)

        // A second store over the same file is the restart: nothing is held in memory
        // between them.
        let reopened = WearerConversationStore(directory: directory)
        let tasks = reopened.entries().filter { $0.kind == .task }
        XCTAssertEqual(tasks.map(\.outcome), [WearerTaskLoop.startedOutcome, "finished"])
        XCTAssertEqual(tasks.map(\.text), [
            "tell me whether the tests passed",
            "tell me whether the tests passed",
        ])
        // And it reads as itself in the recall window, rather than as an unknown kind.
        let lines = tasks.map { WearerConversationRecall.line(for: $0) }
        XCTAssertEqual(lines.first, "The wearer asked TapQ to: tell me whether the tests passed")
        XCTAssertEqual(lines.last, "TapQ's task (finished): tell me whether the tests passed")
    }

    func testAnInterruptedTaskLeavesAStartedEntryWithNoEnding() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tapq-task-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WearerConversationStore(directory: directory)
        let surfaces = RecordingTaskSurfaces()
        var wired = surfaces.make()
        wired.recordTask = { goal, outcome in
            store.recordTask(goal: goal, outcome: outcome)
        }
        let loop = WearerTaskLoop(model: HangingTaskReasoner(), surfaces: wired)

        _ = loop.begin(goal: "watch the build")
        // No cancel and no ending: this is the runtime dying mid-task.

        let reopened = WearerConversationStore(directory: directory)
        let tasks = reopened.entries().filter { $0.kind == .task }
        XCTAssertEqual(tasks.map(\.outcome), [WearerTaskLoop.startedOutcome])
        XCTAssertEqual(tasks.first?.text, "watch the build")

        loop.cancel()
    }

    // MARK: - queue_instruction

    func testAQueuedInstructionIsAnnouncedOutLoud() async {
        let surfaces = RecordingTaskSurfaces()
        surfaces.queueAnswer = .announcing(
            "Queued for Codex.",
            say: "I've told Codex: rerun the failing suite"
        )
        let (loop, _) = makeLoop([
            .decide(.queueInstruction(agent: "Codex", text: "rerun the failing suite")),
            .decide(.finish(summary: "Codex is on it.")),
        ], surfaces: surfaces)

        _ = loop.begin(goal: "have Codex rerun the failing suite")
        await awaitIdle(loop)

        XCTAssertEqual(surfaces.queued.map(\.agent), ["Codex"])
        // The announcement is spoken *before* the summary, so an instruction leaving in the
        // wearer's name is never something they only find out about at the end.
        XCTAssertEqual(surfaces.spoken, [
            "I've told Codex: rerun the failing suite",
            "Codex is on it.",
        ])
    }
}
