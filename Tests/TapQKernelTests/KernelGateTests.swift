import Foundation
import XCTest
@testable import TapQKernel

/// Invariant 6: an approve, deny or answer acts only for the head, only after a verbatim
/// reading of its prompt played, and only for speech that started after that.
///
/// Every method is `async`: on Linux the Swift 6 test-discovery shim cannot register a
/// synchronous method on a `@MainActor` XCTestCase.
@MainActor
final class KernelGateTests: XCTestCase {
    private let npmInstall = PermissionRequest.bash("p1", "npm install")
    private let prompt = "Claude Code wants to run npm install. Allow it?"

    /// A working Claude whose permission prompt has played verbatim at `playedAt`.
    private func askedPermission(playedAt: TimeInterval = 100) async throws -> KernelHarness {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(npmInstall))
        await harness.speaking(prompt)
        harness.output.play(at: playedAt, verbatim: true)
        return harness
    }

    func testSpeechThatStartedBeforeThePromptPlayedIsRefusedAndAskedAgain() async throws {
        let harness = try await askedPermission(playedAt: 100)
        let item = harness.say("Claude, yes", at: 99.5)
        await harness.approve()

        await harness.hear("I'll ask again.")
        await harness.speaking(prompt)
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .gateClosed)))
        XCTAssertEqual(harness.claude.permissions, [])
        await harness.finish()
    }

    func testSpeechThatStartedAfterThePromptPlayedResolves() async throws {
        let harness = try await askedPermission(playedAt: 100)
        harness.say("Claude, yes", at: 100.5)
        await harness.approve()

        await harness.speaking("Allowed for Claude Code.")
        XCTAssertEqual(harness.claude.permissions,
                       [.init(id: "p1", decision: .allow(always: false))])
        XCTAssertTrue(harness.entries.contains(
            .resolved(agent: .claude, requestID: "p1", decision: .permission(.allow(always: false)))))
        await harness.finish()
    }

    func testSpeechWithNoStartInstantIsRefused() async throws {
        let harness = try await askedPermission()
        let item = harness.say("Claude, yes", at: .some(nil))
        await harness.approve()

        await harness.speaking("I'll ask again.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .gateClosed)))
        XCTAssertEqual(harness.claude.permissions, [])
        await harness.finish()
    }

    /// The status channel says when condition (b) holds, so a host can show it: not before
    /// the verbatim reading, not after a paraphrase, and again once it is read word for word.
    func testTheStatusSaysWhenThePromptWasReadWordForWord() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(npmInstall))
        await harness.speaking(prompt)
        XCTAssertEqual(harness.lastReport?.agents.first?.pending.map(\.played), [false])

        harness.output.play(at: 100, verbatim: false)
        await harness.hear("I'll ask again.")
        await harness.speaking(prompt)
        XCTAssertEqual(harness.lastReport?.agents.first?.pending.map(\.played), [false])

        harness.output.play(at: 101, verbatim: true)
        await waitUntil("the reading to reach the status") {
            harness.lastReport?.agents.first?.pending.map(\.played) == [true]
        }
        await harness.finish()
    }

    func testAHeadThatChangedDuringTheIntentCallIsRefused() async throws {
        let harness = try await askedPermission(playedAt: 100)
        harness.claude.emit(.permission(.bash("p2", "rm -rf build")))
        let item = harness.say("Claude, yes", at: 101)
        await waitUntil("the intent call") { harness.intent.model.inputs.count == 2 }
        XCTAssertEqual(harness.intent.model.inputs.last?.pending?.requestID, "p1")

        harness.claude.emit(.withdrawn(requestID: "p1"))
        await harness.waitForEntry("withdrawn") { $0 == .withdrawn(agent: .claude, requestID: "p1") }
        await harness.approve()

        await harness.waitForEntry("refused") { $0 == .refused(itemID: item, reason: .notHead) }
        XCTAssertEqual(harness.claude.permissions, [], "nothing the user did not hear is approved")
        await harness.finish()
    }

    /// V1 P2-3: never silent, even when there is nothing to answer.
    func testAnApprovalWithNothingPendingIsAnswered() async throws {
        let harness = try KernelHarness()
        await harness.start()
        let item = harness.say("Claude, yes")
        await harness.decide(.approve(requestID: "launch-9", always: false))

        await harness.speaking("Nothing is waiting on you.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .nothingPending)))
        await harness.finish()
    }

    /// V1 P2-5: the re-ask answers what the user just said, so it goes ahead of the other
    /// agent's waiting prompt.
    func testAReaskGoesAheadOfTheOtherAgentsPrompt() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch(.claude)
        await harness.launch(.codex)
        harness.claude.emit(.permission(npmInstall))
        await harness.speaking(prompt)
        // The user keeps talking, so nothing else starts until the re-ask is queued.
        harness.input.emit(.speechStarted(itemID: "hold", at: harness.now()))
        await harness.settle()
        harness.codex.emit(.permission(.bash("c1", "make")))
        await harness.settle()
        harness.output.play(at: 100, verbatim: true)
        await harness.settle()
        let item = harness.say("Claude, yes", at: 99.5)
        await harness.approve()
        await harness.waitForEntry("refused") { $0 == .refused(itemID: item, reason: .gateClosed) }

        harness.input.emit(.speechStopped(itemID: "hold"))
        await harness.hear("I'll ask again.")
        await harness.hear(prompt)
        await harness.speaking("Codex wants to run make. Allow it?")
        await harness.finish()
    }

    func testAnAnswerMissingAQuestionIsRefusedAndAskedAgain() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        let questions = QuestionRequest(id: "q1", questions: [
            Question(key: "db", header: nil, text: "Which database?",
                     options: [QuestionOption(label: "Postgres"), QuestionOption(label: "SQLite")],
                     multiSelect: false, allowsFreeText: true),
            Question(key: "ci", header: nil, text: "Which CI?", options: [],
                     multiSelect: false, allowsFreeText: true),
        ])
        harness.claude.emit(.question(questions))
        let prompt = "Claude Code has 2 questions. One: Which database? Options: Postgres or SQLite. "
            + "Two: Which CI?"
        await harness.hear(prompt)

        let item = harness.say("Claude, SQLite")
        await harness.decide { .answer(requestID: $0.pending?.requestID ?? "", answers: [["SQLite"]]) }
        await harness.hear("I'll ask again.")
        await harness.hear(prompt)
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .incompleteAnswer)))

        harness.say("Claude, SQLite and GitHub Actions")
        await harness.decide {
            .answer(requestID: $0.pending?.requestID ?? "", answers: [["SQLite"], ["GitHub Actions"]])
        }
        await harness.speaking("Claude Code has your answer.")
        XCTAssertEqual(harness.claude.answers, [.init(id: "q1", answers: [["SQLite"], ["GitHub Actions"]])])
        await harness.finish()
    }
}

/// The lead's paraphrase ruling (§4.4): a consent prompt read non-verbatim is asked once
/// more, and a second misreading refuses the request out loud.
@MainActor
final class KernelParaphraseTests: XCTestCase {
    private let feedback = "TapQ could not read this request aloud to the user; ask again in simpler terms"

    func testAMisreadPromptIsAskedAgainAndTheGateStaysClosed() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        await harness.hear("Claude Code wants to run npm install. Allow it?", verbatim: false)
        await harness.hear("I'll ask again.")
        await harness.speaking("Claude Code wants to run npm install. Allow it?")

        let item = harness.say("Claude, yes")
        await harness.approve()
        await harness.waitForEntry("refused") { $0 == .refused(itemID: item, reason: .gateClosed) }
        XCTAssertEqual(harness.claude.permissions, [])
        await harness.finish()
    }

    func testAPermissionMisreadTwiceIsDeniedOutLoud() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        await harness.hear("Claude Code wants to run npm install. Allow it?", verbatim: false)
        await harness.hear("I'll ask again.")
        await harness.hear("Claude Code wants to run npm install. Allow it?", verbatim: false)

        await harness.speaking("I couldn't read Claude Code's request reliably, so I said no.")
        XCTAssertEqual(harness.claude.permissions, [.init(id: "p1", decision: .deny(feedback: feedback))])
        XCTAssertEqual(Array(harness.entries.suffix(3)), [
            .refused(itemID: "p1", reason: .unreadable),
            .resolved(agent: .claude, requestID: "p1", decision: .permission(.deny(feedback: feedback))),
            .spoke(id: SpeechID(raw: 5),
                   text: "I couldn't read Claude Code's request reliably, so I said no."),
        ])
        await harness.finish()
    }

    func testAQuestionMisreadTwiceIsAnsweredWithTheReasonForEveryQuestion() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        let question = Question(key: "k", header: nil, text: "Ready?", options: [],
                                multiSelect: false, allowsFreeText: true)
        harness.claude.emit(.question(QuestionRequest(id: "q1", questions: [question, question])))
        let prompt = "Claude Code has 2 questions. One: Ready? Two: Ready?"
        await harness.hear(prompt, verbatim: false)
        await harness.hear("I'll ask again.")
        await harness.hear(prompt, verbatim: false)

        await harness.speaking("I couldn't read Claude Code's request reliably, so I said no.")
        XCTAssertEqual(harness.claude.answers, [.init(id: "q1", answers: [[feedback], [feedback]])])
        await harness.finish()
    }

    /// A switch, the one start still asked (2026-10-24), misread twice is declined.
    func testASwitchMisreadTwiceIsDeclined() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.say("Claude, what conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.claude, .success([.made("a", "build milestone one"), .made("b", "fix the README", daysAgo: 1)]))
        await harness.hear("Claude Code has 2 conversations in workspace. "
            + "1, today: build milestone one. 2, yesterday: fix the README.")
        harness.say("Claude, the second one")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch Claude Code to conversation 2: fix the README?", verbatim: false)
        await harness.hear("I'll ask again.")
        await harness.hear("Switch Claude Code to conversation 2: fix the README?", verbatim: false)

        await harness.speaking("I couldn't read Claude Code's request reliably, so I said no.")
        XCTAssertEqual(harness.claude.starts, [])
        XCTAssertTrue(harness.entries.contains {
            if case .resolved(.claude, _, .launch(yes: false)) = $0 { return true }
            return false
        })
        XCTAssertEqual(harness.phase(.claude), AgentPhase.none)
        await harness.finish()
    }

    func testAMisreadResultIsOnlyLogged() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.finished(text: "Tests pass."))
        await harness.hear("Claude Code says: Tests pass.", verbatim: false)

        await waitUntil("the paraphrase log") { !harness.sink.named("tts.paraphrase").isEmpty }
        XCTAssertEqual(harness.sink.named("tts.paraphrase").first?.fields["kind"], "result")
        XCTAssertNil(harness.output.current, "nothing is said again")
        await harness.finish()
    }
}
