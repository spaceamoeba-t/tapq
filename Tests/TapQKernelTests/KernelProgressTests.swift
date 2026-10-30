import Foundation
import TapQContracts
@testable import TapQKernel
import XCTest

/// A status asked while an agent works says where it is in the whole task, in the progress
/// summarizer's words; never its last tool line, which read shell commands aloud (maintainer,
/// 2026-10-15).
@MainActor
final class KernelProgressTests: XCTestCase {
    func testAStatusWhileWorkingIsTheTurnSummarizedNeverTheToolLine() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.said("Running the test suite now."))
        harness.claude.emit(.progress("Bash: swift test --filter KernelLoopTests 2>&1 | tail -5"))
        await harness.settle()
        XCTAssertNil(harness.output.current, "the agent's words along the way are never spoken on their own")
        XCTAssertEqual(harness.agentReport(.claude)?.progress,
                       "Bash: swift test --filter KernelLoopTests 2>&1 | tail -5", "a host still shows the tool line")

        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        let turn = await harness.summarizeProgress(.success("Claude Code is running the kernel's loop tests."))
        XCTAssertEqual(turn?.asked, ["run the tests"])
        XCTAssertEqual(turn?.said, ["Running the test suite now."])
        XCTAssertEqual(turn?.steps.map(\.line), ["Bash: swift test --filter KernelLoopTests 2>&1 | tail -5"])
        XCTAssertEqual(turn?.stepCount, 1)
        await harness.speaking("Claude Code is running the kernel's loop tests.")
        XCTAssertFalse(harness.output.texts.contains { $0.contains("swift test") })
        await harness.finish()
    }

    /// A step runs until the agent says it ended, and the summarizer is told which steps still
    /// run: live, a status said the check script "has run" while it slept (2026-10-15). The
    /// status channel's tool line stays the last one started.
    func testTheSummarizerIsToldWhichStepsStillRun() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: List the workspace", step: "toolu_1"))
        harness.claude.emit(.stepEnded(step: "toolu_1", .done))
        harness.claude.emit(.progress("Bash: Push the branch", step: "toolu_2"))
        harness.claude.emit(.stepEnded(step: "toolu_2", .declined))
        harness.claude.emit(.progress("Bash: Run check.sh with argument 40", step: "toolu_3"))
        harness.claude.emit(.stepEnded(step: "toolu_9", .failed))
        await harness.settle()
        XCTAssertEqual(harness.agentReport(.claude)?.progress, "Bash: Run check.sh with argument 40")
        XCTAssertEqual(harness.agentReport(.claude)?.progressState, .running,
                       "the channel's line carries its own step's state (2026-10-19)")

        harness.say("Claude, where are you with the task?")
        await harness.decide(.status)
        var turn = await harness.summarizeProgress(.success("Claude Code is running the check script."))
        XCTAssertEqual(turn?.steps.map(\.line), ["Bash: List the workspace", "Bash: Push the branch",
                                                 "Bash: Run check.sh with argument 40"])
        XCTAssertEqual(turn?.steps.map(\.state), [.done, .declined, .running])
        XCTAssertEqual(harness.sink.named("progress.steps").first?.fields,
                       ["agent": "claude", "done": "1", "declined": "1", "running": "1"], "counts only")
        await harness.speaking("Claude Code is running the check script.")

        harness.claude.emit(.stepEnded(step: "toolu_3", .done))
        await harness.settle()
        XCTAssertEqual(harness.agentReport(.claude)?.progress, "Bash: Run check.sh with argument 40")
        XCTAssertEqual(harness.agentReport(.claude)?.progressState, .done)
        harness.say("Claude, and now?")
        await harness.decide(.status)
        turn = await harness.summarizeProgress(.success("Claude Code has run the check script."))
        XCTAssertEqual(turn?.steps.map(\.state), [.done, .declined, .done])
        await harness.finish()
    }

    /// A step that asked the user's permission waits on them, and runs once allowed.
    func testAStepWaitsWhileItsPermissionIsAsked() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: Run check.sh with argument 40", step: "toolu_1"))
        harness.claude.emit(.permission(PermissionRequest(id: "p1", tool: "Bash", inputJSON: "{}",
                                                          command: "./check.sh 40", step: "toolu_1")))
        await harness.hear("Claude Code wants to run ./check.sh 40. Allow it?")
        XCTAssertEqual(harness.agentReport(.claude)?.progressState, .waiting)
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        var turn = await harness.summarizeProgress(.success("Claude Code is waiting to run the check script."))
        XCTAssertEqual(turn?.steps.map(\.state), [.waiting])
        await harness.hear("Claude Code is waiting to run the check script. "
                           + "It's waiting on you: Claude Code wants to run ./check.sh 40. Allow it?")

        harness.say("Claude, yes")
        await harness.approve()
        await harness.hear("Allowed for Claude Code.")
        XCTAssertEqual(harness.agentReport(.claude)?.progressState, .running)
        harness.say("Claude, and now?")
        await harness.decide(.status)
        turn = await harness.summarizeProgress(.success("Claude Code is running the check script."))
        XCTAssertEqual(turn?.steps.map(\.state), [.running])
        await harness.hear("Claude Code is running the check script.")

        // A line with no id says nothing of its state; a turn's end takes the line away.
        harness.claude.emit(.progress("Thinking", step: nil))
        await harness.settle()
        XCTAssertEqual(harness.agentReport(.claude)?.progress, "Thinking")
        XCTAssertNil(harness.agentReport(.claude)?.progressState)
        harness.claude.emit(.finished(text: "Done."))
        await harness.hear("Claude Code says: Done.")
        XCTAssertNil(harness.agentReport(.claude)?.progress)
        XCTAssertNil(harness.agentReport(.claude)?.progressState)
        await harness.finish()
    }

    /// A withdrawn request no longer holds its step: the agent may run it, a hook of the user's
    /// having allowed it (review of the change).
    func testAWithdrawnRequestsStepRunsAgain() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: Run the tests", step: "toolu_1"))
        harness.claude.emit(.permission(PermissionRequest(id: "p1", tool: "Bash", inputJSON: "{}",
                                                          command: "swift test", step: "toolu_1")))
        await harness.hear("Claude Code wants to run swift test. Allow it?")
        harness.claude.emit(.withdrawn(requestID: "p1"))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        let turn = await harness.summarizeProgress(.success("Claude Code is running the tests."))
        XCTAssertEqual(turn?.steps.map(\.state), [.running])
        await harness.finish()
    }

    /// A step's end after its turn is over, or before any turn, changes nothing.
    func testAStepEndOutsideATurnChangesNothing() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.claude.emit(.stepEnded(step: "toolu_1", .done))
        await harness.settle()
        XCTAssertEqual(harness.agentReport(.claude)?.phase, AgentPhase.none)
        await harness.launch()
        harness.claude.emit(.progress("Bash: Run the tests", step: "toolu_1"))
        harness.claude.emit(.finished(text: "Done."))
        harness.claude.emit(.stepEnded(step: "toolu_1", .done))
        await harness.settle()
        XCTAssertEqual(harness.fatal.reasons, [])
        await harness.finish()
    }

    /// A failed, empty or wordless summary is told as a failure, out loud (maintainer,
    /// 2026-10-16): never passed off as a status, nor filled with the agent's own words, which
    /// can hold a command (review of f98bb4e).
    func testAFailedSummaryIsToldOutLoud() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: rm -rf build && make"))
        harness.claude.emit(.said("Running `./check.sh 40 && rm -rf build` now."))
        await harness.settle()
        for (index, result) in [Result<String, TextModelError>.failure(.callBound("timeout")),
                                .success("  "), .success("```\n```")].enumerated() {
            harness.say("Claude, status?")
            await harness.decide(.status)
            await harness.summarizeProgress(result)
            let failed = "Claude Code is working, but I couldn't summarize where it is."
            await harness.hear(failed)
            XCTAssertEqual(harness.output.texts.filter { $0 == failed }.count, index + 1)
        }
        XCTAssertFalse(harness.output.texts.contains { $0.contains("rm -rf") || $0.contains("check.sh") })
        XCTAssertEqual(harness.fatal.reasons, [])
        await harness.finish()
    }

    /// A shell command's prompt is the command read whole until its description arrives; a
    /// status in that time leaves it out, and the described prompt is asked on its own.
    func testAStatusLeavesOutARequestStillBeingDescribed() async throws {
        let harness = try KernelHarness()
        harness.describer.manual = true
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: rm -rf build"))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await waitUntil("the progress call") { harness.progress.model.inputs.count == 1 }
        harness.claude.emit(.permission(.bash("p1", "rm -rf build")))
        await harness.settle()
        await harness.summarizeProgress(.success("Claude Code is clearing the build."))
        await harness.hear("Claude Code is clearing the build.")
        await harness.describe(.success("delete the build folder"))
        await harness.speaking("Claude Code wants to delete the build folder. Allow it?")
        XCTAssertFalse(harness.output.texts.contains { $0.contains("rm -rf") })
        await harness.finish()
    }

    /// A steer that crosses its turn's end runs as the next turn, one TapQ did not start: that
    /// turn is asked what the steer asked. A turn TapQ starts drops it.
    func testASteerThatCrossesTheEndAsksTheNextTurn() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: swift test"))
        await harness.settle()
        harness.say("Claude, also update the README.")
        await harness.decide(.instruct(text: "also update the README"))
        await harness.hear("Okay, I'll add that.")
        harness.claude.emit(.finished(text: "Tests pass."))
        await harness.hear("Claude Code says: Tests pass.")

        harness.claude.emit(.progress("Edit: README.md"))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        var turn = await harness.summarizeProgress(.success("Claude Code is updating the README."))
        XCTAssertEqual(turn?.asked, ["also update the README"])
        await harness.hear("Claude Code is updating the README.")

        harness.claude.emit(.finished(text: "Updated."))
        await harness.hear("Claude Code says: Updated.")
        harness.claude.emit(.progress("Bash: swiftlint"))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        turn = await harness.summarizeProgress(.success("Claude Code is linting."))
        XCTAssertEqual(turn?.asked, [], "carried once, into the turn right after")
        await harness.hear("Claude Code is linting.")
        await harness.finish()
    }

    func testAStatusBeforeTheAgentShowsAnyWorkAsksNoModel() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await harness.speaking("Claude Code is working.")
        XCTAssertEqual(harness.progress.model.inputs.count, 0)
        await harness.finish()
    }

    func testASummaryOfATurnThatEndedIsDropped() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: swift test"))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await waitUntil("the progress call") { harness.progress.model.inputs.count == 1 }

        harness.claude.emit(.finished(text: "All tests pass."))
        await harness.hear("Claude Code says: All tests pass.")
        await harness.settle()
        XCTAssertEqual(harness.output.texts.filter { $0.hasPrefix("Claude Code is") }, [],
                       "the reply is what the user hears; the call was cancelled with the turn")
        XCTAssertEqual(harness.phase(.claude), .idle)
        await harness.finish()
    }

    func testASteerJoinsItsTurnAndTheNextTurnStartsAfresh() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: swift build"))
        await harness.settle()
        harness.say("Claude, also update the README.")
        await harness.decide(.instruct(text: "also update the README"))
        await harness.hear("Okay, I'll add that.")
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        var turn = await harness.summarizeProgress(.success("Claude Code is building, then it will update the README."))
        XCTAssertEqual(turn?.asked, ["run the tests", "also update the README"])
        await harness.hear("Claude Code is building, then it will update the README.")

        harness.claude.emit(.said("Done."))
        harness.claude.emit(.finished(text: "Done."))
        await harness.hear("Claude Code says: Done.")
        harness.say("Claude, lint the code.")
        await harness.decide(.instruct(text: "lint the code"))
        await harness.hear("Okay.")
        harness.claude.emit(.progress("Bash: swiftlint"))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        turn = await harness.summarizeProgress(.success("Claude Code is linting the code."))
        XCTAssertEqual(turn?.asked, ["lint the code"])
        XCTAssertEqual(turn?.said, [])
        XCTAssertEqual(turn?.steps.map(\.line), ["Bash: swiftlint"])
        await harness.speaking("Claude Code is linting the code.")
        await harness.finish()
    }

    func testASecondStatusWhileOneIsOnItsWayIsAnsweredByThatOne() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: swift test"))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        harness.say("Claude, status?")
        await harness.decide(.status)
        await harness.settle()
        XCTAssertEqual(harness.progress.model.inputs.count, 1)
        await harness.summarizeProgress(.success("Claude Code is running the tests."))
        await harness.hear("Claude Code is running the tests.")
        await harness.settle()
        XCTAssertEqual(harness.output.texts.filter { $0 == "Claude Code is running the tests." }.count, 1)
        await harness.finish()
    }

    /// A turn TapQ did not start (Claude Code waking on its own) gets a record at its first
    /// event, so its status is summarized too.
    func testATurnTheKernelDidNotStartIsSummarized() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.finished(text: "Started the check in the background."))
        await harness.hear("Claude Code says: Started the check in the background.")
        harness.claude.emit(.said("The background check finished; reading its output."))
        await harness.settle()
        XCTAssertEqual(harness.phase(.claude), .working)
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        let turn = await harness.summarizeProgress(.success("Claude Code is reading the check's output."))
        XCTAssertEqual(turn?.asked, [])
        XCTAssertEqual(turn?.said, ["The background check finished; reading its output."])
        await harness.speaking("Claude Code is reading the check's output.")
        await harness.finish()
    }

    func testAContractFailureIsFatal() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: swift test"))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await harness.summarizeProgress(.failure(.contract("HTTP 400")))
        await harness.ended()
        XCTAssertEqual(harness.fatal.reasons, [FatalReason(subsystem: "progress", reason: "HTTP 400")])
    }
}
