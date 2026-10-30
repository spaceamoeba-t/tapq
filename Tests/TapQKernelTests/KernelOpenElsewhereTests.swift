import Foundation
import XCTest
@testable import TapQKernel

/// A conversation another process has open, the Claude app's, a terminal's, a background
/// session's: TapQ says so when it reads the list or is asked what an agent that is off is doing,
/// and resumes none of them (maintainer, 2026-10-12), nor offers one to the picker (2026-10-24).
/// Every look is fresh; a look that cannot tell changes nothing.
@MainActor
final class KernelOpenElsewhereTests: XCTestCase {
    private var harness: KernelHarness!

    override func setUp() async throws {
        harness = try KernelHarness()
    }

    override func tearDown() async throws {
        await harness.finish()
        harness = nil
    }

    private static let inTheApp = OpenSession(id: "app", title: "Music medley study", working: true)

    private func listClaude(_ sessions: [SessionSummary], heard: String) async {
        harness.say("Claude, what conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.claude, .success(sessions))
        await harness.hear(heard)
    }

    // MARK: - Said

    func testAConversationOpenElsewhereIsMarkedWhenRead() async throws {
        harness.claudeCatalog.openNow = [Self.inTheApp]
        await harness.start()
        await listClaude([.made("app", "Music medley study"), .made("old", "fix the README", daysAgo: 1)],
                         heard: "Claude Code has 2 conversations in workspace. "
                            + "1, today, open elsewhere: Music medley study. 2, yesterday: fix the README.")
        XCTAssertEqual(harness.agentReport(.claude)?.conversations?.read.map(\.openElsewhere), [true, nil])
        XCTAssertEqual(harness.claudeCatalog.looks, 1)
    }

    func testAnAgentThatIsOffIsSaidToBeAtWorkElsewhere() async throws {
        harness.claudeCatalog.openNow = [Self.inTheApp,
                                         OpenSession(id: "term", title: "fix the README.", working: false)]
        await harness.start()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await harness.hear("Claude Code isn't running in TapQ, but 2 of its conversations are open elsewhere: "
                           + "Music medley study, working; fix the README, idle.")

        // Nothing open elsewhere: the sentence of before.
        harness.claudeCatalog.openNow = []
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await harness.hear("Claude Code isn't running.")
        XCTAssertEqual(harness.claudeCatalog.looks, 2)
    }

    // MARK: - Not resumed

    func testASwitchToAConversationOpenElsewhereIsRefusedUntilItIsClosedThere() async throws {
        harness.claudeCatalog.openNow = [Self.inTheApp]
        await harness.start()
        await listClaude([.made("app", "Music medley study")],
                         heard: "Claude Code has 1 conversation in workspace. 1, today, open elsewhere: Music medley study.")

        let item = harness.say("Claude, continue the one from the Claude app.")
        await harness.decide(.switchConversation(number: 1, text: nil))
        await harness.hear("I can't continue conversation 1 while it's open elsewhere. "
                           + "Close it there and ask again, or say: Claude Code, new conversation.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .openElsewhere)), "\(harness.entries)")
        XCTAssertEqual(harness.phase(.claude), AgentPhase.none)
        XCTAssertFalse(harness.entries.contains { if case .launchAsked = $0 { return true } else { return false } })

        // Closed in the app: the next look is fresh, and the switch is asked as any is.
        harness.claudeCatalog.openNow = []
        harness.say("Claude, switch to conversation 1.")
        await harness.decide(.switchConversation(number: 1, text: nil))
        await harness.hear("Switch Claude Code to conversation 1: Music medley study?")
        XCTAssertEqual(harness.agentReport(.claude)?.conversations?.read.map(\.openElsewhere), [nil],
                       "the mark follows the last look")
    }

    /// The conversation it was last in, open elsewhere, is never offered: the words start a new
    /// one, and the user hears why (2026-10-24).
    func testTheConversationTheAgentWouldResumeIsNotResumedWhileOpenElsewhere() async throws {
        harness = try KernelHarness(sessionIDs: [.claude: "saved"])
        harness.claudeCatalog.openNow = [OpenSession(id: "saved", title: "run the tests", working: false)]
        await harness.start()
        harness.say("Claude, run the tests.")
        await harness.decide(.instruct(text: "run the tests"))
        await harness.offer(.claude, .success([.made("saved", "run the tests")]))
        await harness.hear("Okay, Claude Code starts a new conversation. Its last one is open elsewhere.")
        XCTAssertEqual(harness.claude.starts, [.fresh])
        XCTAssertEqual(harness.picker.model.inputs, [])
        XCTAssertEqual(harness.claudeCatalog.looks, 1)

        // A new conversation resumes nothing, so nothing is looked up.
        harness.claude.emit(.finished(text: "Tests pass."))
        await harness.hear("Claude Code says: Tests pass.")
        harness.say("Claude, start a new conversation and run the tests.")
        await harness.decide(.newConversation(text: "run the tests"))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.claudeCatalog.looks, 1)
        XCTAssertEqual(harness.claude.starts, [.fresh])
    }

    func testAFreshStartLooksUpNothing() async throws {
        await harness.start()
        await harness.launch()
        XCTAssertEqual(harness.claudeCatalog.looks, 0, "no saved conversation, nothing resumed")
    }

    // MARK: - TapQ's own

    func testTheConversationTapQsOwnProcessIsInIsNotOpenElsewhere() async throws {
        // Claude Code lists TapQ's own child among the sessions it runs (live, 2026-10-12).
        harness.claudeCatalog.openNow = [OpenSession(id: "session-new", title: "run the tests", working: false),
                                         Self.inTheApp]
        await harness.start()
        await harness.launch()
        harness.claude.emit(.finished(text: "Tests pass."))
        await harness.hear("Claude Code says: Tests pass.")
        await listClaude([.made("session-new", "run the tests"), .made("app", "Music medley study")],
                         heard: "Claude Code has 2 conversations in workspace. 1, today, the current one: run the tests. "
                            + "2, today, open elsewhere: Music medley study.")

        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await harness.hear("Claude Code is idle.")
        XCTAssertEqual(harness.claudeCatalog.looks, 1, "a running agent's status is its own")

        harness.say("Claude, switch to the second one.")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("I can't continue conversation 2 while it's open elsewhere. "
                           + "Close it there and ask again, or say: Claude Code, new conversation.")
        XCTAssertEqual(harness.phase(.claude), .idle)
        XCTAssertFalse(harness.claude.stopped)
    }

    // MARK: - Cannot tell

    func testALookThatFailsMarksNothingAndRefusesNothing() async throws {
        harness.claudeCatalog.openManual = true
        await harness.start()
        harness.say("Claude, what conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.claude, .success([.made("app", "Music medley study")]))
        await answerLook(.failure(.callBound("claude agents exited 1")))
        await harness.hear("Claude Code has 1 conversation in workspace. 1, today: Music medley study.")

        harness.say("Claude, switch to conversation 1.")
        await harness.decide(.switchConversation(number: 1, text: nil))
        await answerLook(.failure(.callBound("claude agents exited 1")))
        await harness.hear("Switch Claude Code to conversation 1: Music medley study?")
    }

    func testALookPastItsBoundIsGoneOnWithout() async throws {
        harness = try KernelHarness(sessionIDs: [.claude: "saved"], openTimeout: .milliseconds(50))
        harness.claudeCatalog.openManual = true
        await harness.start()
        harness.say("Claude, run the tests.")
        await harness.decide(.instruct(text: "run the tests"))
        await harness.offer(.claude, .success([.made("saved", "run the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, Claude Code continues its last conversation.")
        XCTAssertEqual(harness.claudeCatalog.looks, 1)
        XCTAssertEqual(harness.claude.starts, [.resume(id: "saved")])
    }

    /// Answers the next look the kernel is waiting on.
    private func answerLook(_ result: Result<[OpenSession], TextModelError>,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let catalog = harness.claudeCatalog
        let answered = catalog.openModel.replies
        await waitUntil("look \(answered + 1)", file: file, line: line) { catalog.openModel.inputs.count > answered }
        catalog.openModel.reply(result)
    }
}
