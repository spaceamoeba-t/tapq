import XCTest
import TapQContracts
@testable import TapQKernel

/// A shell command is asked with what it does, not read (maintainer ruling 2026-10-12).
@MainActor
final class KernelDescriptionTests: XCTestCase {
    private let command = "rm -rf build && npm run build"

    private func harness() async throws -> KernelHarness {
        let harness = try KernelHarness()
        harness.describer.manual = true
        await harness.start()
        await harness.launch()
        return harness
    }

    func testACommandIsAskedWithItsDescriptionAndTheStatusKeepsTheCommand() async throws {
        let harness = try await harness()
        harness.claude.emit(.permission(.bash("p1", command)))
        let described = await harness.describe(.success("Delete the build folder, then build the project with npm."))
        XCTAssertEqual(described, command)
        XCTAssertEqual(harness.describer.model.inputs, [command])

        let prompt = "Claude Code wants to delete the build folder, then build the project with npm. Allow it?"
        await harness.hear(prompt)
        XCTAssertFalse(harness.output.texts.contains { $0.contains("rm -rf") })
        let pending = harness.lastReport?.agents.first { $0.agent == .claude }?.pending
        XCTAssertEqual(pending?.map(\.prompt), [prompt])
        XCTAssertEqual(pending?.map(\.command), [command])
        XCTAssertEqual(pending?.map(\.played), [true])
        XCTAssertEqual(pending?.map(\.describing), [nil], "absent once described")

        harness.say("Claude, yes")
        let input = await harness.approve()
        XCTAssertEqual(input?.pending?.prompt, prompt)
        await harness.speaking("Allowed for Claude Code.")
        XCTAssertEqual(harness.claude.permissions, [.init(id: "p1", decision: .allow(always: false))])
        XCTAssertEqual(harness.sink.named("describer.call").map { $0.fields["outcome"] }, ["ok"])
        await harness.finish()
    }

    /// Nothing is asked before the words arrive, and a yes before the reading is refused.
    func testNothingIsAskedWhileTheDescriptionIsOnItsWay() async throws {
        let harness = try await harness()
        harness.claude.emit(.permission(.bash("p1", command)))
        await waitUntil("the description call") { harness.describer.model.inputs.count == 1 }
        await harness.settle()
        XCTAssertNil(harness.output.current)
        XCTAssertFalse(harness.output.texts.contains { $0.contains("wants to") })
        // The status line says so, so a screen shows the command, not the fallback prompt
        // that reads it (2026-10-16).
        let waiting = harness.lastReport?.agents.first { $0.agent == .claude }?.pending
        XCTAssertEqual(waiting?.map(\.describing), [true])
        XCTAssertEqual(waiting?.map(\.command), [command])

        harness.say("Claude, yes")
        await harness.approve()
        await harness.hear("I'll ask again.")
        XCTAssertEqual(harness.claude.permissions, [])
        await harness.describe(.success("delete the build folder"))
        await harness.hear("Claude Code wants to delete the build folder. Allow it?")
        await harness.finish()
    }

    func testACallBoundFailureOrEmptyWordsReadTheCommand() async throws {
        for result: Result<String, TextModelError> in [.failure(.callBound("timeout")), .success(" \"\" . ")] {
            let harness = try await harness()
            harness.claude.emit(.permission(.bash("p1", command)))
            await harness.describe(result)
            await harness.hear("Claude Code wants to run \(command). Allow it?")
            await harness.finish()
        }
    }

    /// A command can name the workspace by the path the user picked or by where it leads:
    /// live, Claude Code's `/private/var/…` was called "outside the project" when the describer
    /// knew only `/var/…` (2026-10-15). Without a link it is the one path.
    func testTheDescriberIsGivenEveryPathThatNamesTheWorkspace() async throws {
        let resolved = "/private/tmp/projects/workspace"
        for (realPath, expected) in [(resolved, [KernelHarness.workspace.path, resolved]),
                                     (KernelHarness.workspace.path, [KernelHarness.workspace.path]),
                                     (nil, [KernelHarness.workspace.path])] {
            let harness = try KernelHarness(workspaceRealPath: realPath)
            harness.describer.manual = true
            await harness.start()
            await harness.launch()
            harness.claude.emit(.permission(.bash("p1", "git -C \(resolved) ls-files")))
            await harness.describe(.success("list the project's tracked files with git"))
            XCTAssertEqual(harness.describer.workspacePaths, [expected])
            await harness.hear("Claude Code wants to list the project's tracked files with git. Allow it?")
            await harness.finish()
        }
    }

    func testADescriberContractFailureIsFatal() async throws {
        let harness = try await harness()
        harness.claude.emit(.permission(.bash("p1", command)))
        await harness.describe(.failure(.contract("http 401")))
        await harness.ended()
        XCTAssertEqual(harness.fatal.reasons, [FatalReason(subsystem: "describer", reason: "http 401")])
    }

    func testARequestWithdrawnWhileDescribedIsNeverAsked() async throws {
        let harness = try await harness()
        harness.claude.emit(.permission(.bash("p1", command)))
        await waitUntil("the description call") { harness.describer.model.inputs.count == 1 }
        harness.claude.emit(.withdrawn(requestID: "p1"))
        await harness.waitForEntry("withdrawn") { $0 == .withdrawn(agent: .claude, requestID: "p1") }
        // The call is cancelled: its words, had they come, would find nothing to ask.
        await harness.settle()
        XCTAssertNil(harness.output.current)
        XCTAssertFalse(harness.output.texts.contains { $0.contains("wants to") || $0.contains("withdrew") })
        await harness.finish()
    }

    /// The second request waits behind the first, each with its own words, whichever arrive first.
    func testEachRequestIsAskedWithItsOwnDescriptionInOrder() async throws {
        let harness = try await harness()
        harness.claude.emit(.permission(.bash("p1", "rm -rf build")))
        harness.claude.emit(.permission(.bash("p2", "git push --force")))
        await waitUntil("both description calls") { harness.describer.model.inputs.count == 2 }
        // Answered in call order: p1's words, then p2's.
        await harness.describe(.success("delete the build folder"))
        await harness.describe(.success("force-push the current branch, overwriting the remote's history"))
        await harness.hear("Claude Code wants to delete the build folder. Allow it?")
        harness.say("Claude, no")
        await harness.decide { .deny(requestID: $0.pending?.requestID ?? "", feedback: nil) }
        await harness.hear("Denied for Claude Code.")
        await harness.hear("Claude Code wants to force-push the current branch, overwriting the remote's history. Allow it?")
        await harness.finish()
    }

    func testANextHeadStillBeingDescribedIsAskedWhenItsWordsArrive() async throws {
        let harness = try await harness()
        harness.claude.emit(.permission(.bash("p1", "rm -rf build")))
        await harness.describe(.success("delete the build folder"))
        await harness.hear("Claude Code wants to delete the build folder. Allow it?")
        harness.claude.emit(.permission(.bash("p2", "git push --force")))
        await waitUntil("the second description call") { harness.describer.model.inputs.count == 2 }
        harness.say("Claude, yes")
        await harness.approve()
        await harness.hear("Allowed for Claude Code.")
        await harness.settle()
        XCTAssertNil(harness.output.current)
        await harness.describe(.success("force-push the current branch"))
        await harness.hear("Claude Code wants to force-push the current branch. Allow it?")
        await harness.finish()
    }

    func testAnEditIsAskedAtOnceWithoutADescription() async throws {
        let harness = try await harness()
        harness.claude.emit(.permission(PermissionRequest(id: "e1", tool: "Edit", inputJSON: #"{"file_path":"/w/a.swift"}"#,
                                                          paths: ["/w/a.swift"])))
        await harness.hear("Claude Code wants to edit /w/a.swift. Allow it?")
        XCTAssertEqual(harness.describer.model.inputs, [])
        XCTAssertEqual(harness.lastReport?.agents.first { $0.agent == .claude }?.pending.first?.command, nil)
        await harness.finish()
    }
}

final class CommandDescriptionSentenceTests: XCTestCase {
    func testTheDescriptionIsTheMiddleOfTheSentence() {
        let cases: [(phrase: String, agent: AgentID, action: String?)] = [
            ("Delete the build folder.", .claude, "delete the build folder"),
            ("Codex wants to delete the build folder", .codex, "delete the build folder"),
            ("\"fetch example.com with curl\"", .codex, "fetch example.com with curl"),
            ("to run the tests", .claude, "run the tests"),
            ("SSH into the staging server", .claude, "SSH into the staging server"),
            ("**delete** `build`\n and build it again", .claude, "delete build and build it again"),
            ("  . ", .claude, nil),
            ("", .claude, nil),
        ]
        for (phrase, agent, action) in cases {
            XCTAssertEqual(Sentences.describedAction(phrase, agent: agent), action, phrase)
        }
    }

    func testTheReasonFollowsTheDescription() {
        let request = PermissionRequest(id: "c1", tool: "commandExecution", inputJSON: "{}",
                                        command: "rm -rf build", reason: "Clean before the release build")
        XCTAssertEqual(Sentences.permission(.codex, request, described: "delete the build folder"),
                       "Codex wants to delete the build folder. It says: Clean before the release build. Allow it?")
        XCTAssertNil(Sentences.permission(.codex, request, described: "\n"))
    }
}
