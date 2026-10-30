import XCTest
import TapQContracts
@testable import TapQKernel

/// One agent failing stops that agent alone; TapQ and the other agent go on (maintainer
/// ruling 2026-10-12).
@MainActor
final class KernelAgentFailureTests: XCTestCase {
    struct NotLoggedIn: Error, CustomStringConvertible {
        var description: String { "Codex is not logged in; run `codex login`" }
    }

    static let codexQuit = "Codex quit unexpectedly. Its unfinished task stopped, and nothing was resent, "
        + "but Codex may take the task up again when it resumes. Talk to Codex to start it again."

    private func bothWorking() async throws -> KernelHarness {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch(.claude, task: "build milestone two")
        await harness.launch(.codex, task: "write the tests")
        return harness
    }

    func testAnAgentThatExitsIsToldAndTheOtherAgentGoesOn() async throws {
        let harness = try await bothWorking()
        harness.codex.emit(.exited(code: 137, stderrTail: ["killed"]))
        await harness.hear("Codex quit unexpectedly. Its unfinished task stopped, and nothing was resent, "
                           + "but Codex may take the task up again when it resumes. Talk to Codex to start it again.")

        XCTAssertEqual(harness.fatal.reasons, [])
        XCTAssertTrue(harness.entries.contains(.lost(agent: .codex, .turn)))
        XCTAssertEqual(harness.phase(.codex), AgentPhase.none)
        XCTAssertEqual(harness.phase(.claude), .working)
        await waitUntil("the old delegate to be stopped") { harness.codexes[0].stopped }
        XCTAssertEqual(harness.sink.named("delegate.failed").first?.fields,
                       ["agent": "codex", "reason": "exited with code 137", "stderr": "killed"])

        harness.claude.emit(.finished(text: "Done."))
        await harness.hear("Claude Code says: Done.")
        await harness.finish()
    }

    func testTheNextInstructionResumesTheFailedAgentOnAFreshDelegate() async throws {
        let harness = try await bothWorking()
        harness.codex.emit(.exited(code: 1, stderrTail: []))
        await harness.hear(Self.codexQuit)

        harness.say("Codex, continue")
        await harness.decide(.instruct(text: "continue"))
        await harness.offer(.codex, .success([.made("session-new", "write the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, Codex continues its last conversation.")

        XCTAssertEqual(harness.codexes.count, 2)
        XCTAssertEqual(harness.codex.starts, [.resume(id: "session-new")])
        XCTAssertEqual(harness.codex.sent, ["continue"])
        XCTAssertEqual(harness.codexes[0].sent, ["write the tests"])
        XCTAssertEqual(harness.phase(.codex), .working)
        await harness.finish()
    }

    /// The new process starts only once the failed one is gone (D13): never two on one session.
    func testTheNextStartWaitsForTheFailedProcessToStop() async throws {
        let harness = try await bothWorking()
        harness.codexes[0].holdsStop = true
        harness.codex.emit(.exited(code: 1, stderrTail: []))
        await waitUntil("the old delegate's stop") { harness.codexes[0].stopHeld }
        await harness.hear(Self.codexQuit)
        harness.say("Codex, continue")
        await harness.decide(.instruct(text: "continue"))
        await harness.offer(.codex, .success([.made("session-new", "write the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.waitForEntry("the start") {
            if case .launching(.codex, _, _) = $0 { return true } else { return false }
        }
        XCTAssertEqual(harness.codex.starts, [])

        harness.codexes[0].releaseStop()
        await harness.hear("Okay, Codex continues its last conversation.")
        XCTAssertEqual(harness.codex.starts, [.resume(id: "session-new")])
        XCTAssertLessThan(harness.log.index(of: "codex.stopped"), harness.log.calls.lastIndex(of: "codex.start") ?? -1)
        await harness.finish()
    }

    func testAViolationStopsThatAgentWithItsRequestAndItsLateEventsAreDropped() async throws {
        let harness = try await bothWorking()
        harness.claude.emit(.permission(PermissionRequest(id: "e1", tool: "Edit", inputJSON: "{}", paths: ["a.txt"])))
        await harness.hear("Claude Code wants to edit a.txt. Allow it?")
        harness.claude.emit(.violation("system/init reports another session"))
        await harness.hear("TapQ lost track of Claude Code, so it stopped it. Its unfinished task and 1 open request "
                           + "stopped, and nothing was resent. Talk to Claude Code to start it again.")
        XCTAssertTrue(harness.entries.contains(.lost(agent: .claude, .request(id: "e1"))))
        XCTAssertEqual(harness.lastReport?.agents.first { $0.agent == .claude }?.pending, [])
        XCTAssertEqual(harness.agentReport(.claude)?.failure?.kind, .lostTrack)

        // The old process's last words are a past generation's.
        harness.claudes[0].emit(.finished(text: "late"))
        await harness.settle()
        XCTAssertFalse(harness.output.texts.contains("Claude Code says: late"))
        XCTAssertEqual(harness.phase(.claude), AgentPhase.none)
        XCTAssertEqual(harness.fatal.reasons, [])
        await harness.finish()
    }

    func testASendThatThrowsFailsThatAgent() async throws {
        let harness = try await bothWorking()
        harness.claude.emit(.finished(text: "Done."))
        await harness.hear("Claude Code says: Done.")
        harness.claude.sendError = FakeError()
        let okays = harness.output.texts.filter { $0 == "Okay." }.count
        harness.say("Claude, run lint")
        await harness.decide(.instruct(text: "run lint"))
        await harness.hear("TapQ lost track of Claude Code, so it stopped it. Its unfinished task stopped, and "
                           + "nothing was resent. Talk to Claude Code to start it again.")
        XCTAssertTrue(harness.entries.contains(.lost(agent: .claude, .turn)))
        XCTAssertEqual(harness.output.texts.filter { $0 == "Okay." }.count, okays)
        await harness.finish()
    }

    func testAFailedStartIsToldAndTheAgentStaysOff() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.codex.startError = NotLoggedIn()
        harness.say("Codex, list the files")
        await harness.decide(.instruct(text: "list the files"))
        await harness.offer(.codex, .success([]))
        await harness.hear("Codex couldn't start: Codex is not logged in; run codex login.")

        XCTAssertEqual(harness.fatal.reasons, [])
        XCTAssertEqual(harness.phase(.codex), AgentPhase.none)
        XCTAssertEqual(harness.agentReport(.codex)?.failure, StatusReport.Failure(
            kind: .startFailed, sentence: "Codex couldn't start: Codex is not logged in; run codex login."))
        // The start opened a turn for its words; it is closed, so a restart says nothing more of it.
        XCTAssertTrue(harness.entries.contains(.lost(agent: .codex, .turn)))
        XCTAssertFalse(harness.entries.contains { if case .sent = $0 { return true } else { return false } })

        // The next instruction starts it again, on a fresh delegate.
        harness.say("Codex, list the files")
        await harness.decide(.instruct(text: "list the files"))
        await harness.offer(.codex, .success([]))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.codexes.count, 2)
        XCTAssertEqual(harness.codex.starts, [.fresh])
        await harness.finish()
    }

    // MARK: - On the status channel

    /// The panel and the notch say why an agent is off (2026-10-12): from the failure until it
    /// has started again.
    func testTheStatusSaysWhyAnAgentStoppedUntilItStartsAgain() async throws {
        let harness = try await bothWorking()
        harness.codex.emit(.exited(code: 1, stderrTail: []))
        await harness.hear(Self.codexQuit)
        XCTAssertEqual(harness.agentReport(.codex)?.failure,
                       StatusReport.Failure(kind: .exited, sentence: Self.codexQuit))
        XCTAssertNil(harness.agentReport(.claude)?.failure)

        harness.say("Codex, continue")
        await harness.decide(.instruct(text: "continue"))
        await harness.offer(.codex, .success([.made("session-new", "write the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, Codex continues its last conversation.")
        XCTAssertNil(harness.agentReport(.codex)?.failure)
        await harness.finish()
    }

    /// The user heard it fail and keeps it off: a no to switching it, the one start still asked
    /// (2026-10-24), stops the status saying it failed.
    func testANoToStartingAFailedAgentClearsItsFailure() async throws {
        let harness = try await bothWorking()
        harness.codex.emit(.exited(code: 1, stderrTail: []))
        await harness.hear(Self.codexQuit)
        harness.say("Codex, which conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.codex, .success([.made("session-new", "write the tests"),
                                             .made("old-1", "fix the README", daysAgo: 1)]))
        await harness.hear("Codex has 2 conversations in workspace. 1, today, the current one: write the tests. "
                           + "2, yesterday: fix the README.")
        harness.say("Codex, the second one")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch Codex to conversation 2: fix the README?")
        harness.say("Codex, no")
        await harness.decide { .deny(requestID: $0.pending?.requestID ?? "", feedback: nil) }
        await harness.hear("Okay, Codex stays off.")

        XCTAssertNil(harness.agentReport(.codex)?.failure)
        XCTAssertEqual(harness.phase(.codex), AgentPhase.none)
        await harness.finish()
    }

    func testAStartPastItsBoundIsStoppedAndTold() async throws {
        let harness = try KernelHarness(startTimeout: .milliseconds(50))
        await harness.start()
        harness.codex.holdsStart = true
        harness.say("Codex, list the files")
        await harness.decide(.instruct(text: "list the files"))
        await harness.offer(.codex, .success([]))
        await harness.hear("Codex couldn't start: it did not start in time.")
        XCTAssertTrue(harness.codexes[0].stopped)
        XCTAssertEqual(harness.fatal.reasons, [])
        await harness.finish()
    }

    /// What a failure journals is what a restart would: the next run finds nothing to tell.
    func testARestartAfterAnAgentFailureSaysNothingMoreAboutIt() async throws {
        let first = try await bothWorking()
        first.codex.emit(.exited(code: 1, stderrTail: []))
        await first.waitForEntry("lost turn") { $0 == .lost(agent: .codex, .turn) }
        first.claude.emit(.finished(text: "Done."))
        await first.hear("Codex quit unexpectedly. Its unfinished task stopped, and nothing was resent, "
                         + "but Codex may take the task up again when it resumes. Talk to Codex to start it again.")
        await first.hear("Claude Code says: Done.")
        let journal = first.entries
        await first.finish()

        let second = try KernelHarness(seed: journal)
        await second.start()
        await second.settle()
        XCTAssertEqual(second.entries, [])
        XCTAssertNil(second.output.current)
        await second.finish()
    }
}

final class AgentFailureSentenceTests: XCTestCase {
    func testEachFailureIsToldInItsOwnWords() {
        XCTAssertEqual(Sentences.agentFailed(.claude, .exited, openRequests: nil, taskDelivered: false),
                       "Claude Code quit unexpectedly. Talk to Claude Code to start it again.")
        XCTAssertEqual(Sentences.agentFailed(.claude, .lostTrack, openRequests: 2, taskDelivered: true),
                       "TapQ lost track of Claude Code, so it stopped it. Its unfinished task and 2 open requests "
                       + "stopped, and nothing was resent. Talk to Claude Code to start it again.")
        XCTAssertEqual(Sentences.agentFailed(.codex, .startFailed("`codex` exited with code 1"),
                                             openRequests: nil, taskDelivered: false),
                       "Codex couldn't start: codex exited with code 1.")
    }
}
