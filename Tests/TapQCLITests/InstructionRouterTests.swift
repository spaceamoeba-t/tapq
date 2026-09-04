import XCTest
@testable import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQInteractionBaseline

/// The one rule for what happens to a sentence the wearer means for an agent
/// (`docs/WAKE_WORD_PLAN.md` §4).
///
/// The decision table is the whole of the wake word that is not hardware, and it is the
/// reason the routing lives in a portable type at all: three doors reach it, only one of
/// them can be driven from a test on this machine, and the answer has to be the same
/// through all three.
@MainActor
final class InstructionRouterTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var routedTo: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.filter { $0.name == "routed" }.compactMap { $0.fields["to"] }
        }
    }

    // MARK: - The decision table

    /// Something live takes it, and nothing else happens. The live branch is first for the
    /// reason rule 3 gives: the wake word does not mean "new session", it means "here is
    /// something to do", and a session that is running is what does things.
    func testALiveTargetTakesTheSentenceAndNothingIsStarted() async {
        var queued: [String] = []
        var started: [String] = []
        let router = InstructionRouter(
            enqueueToLiveTarget: { text in
                queued.append(text)
                return .queued
            },
            startSession: { goal, _ in
                started.append(goal)
                return .started(agentDisplayName: "Claude Code")
            }
        )

        XCTAssertEqual(router.route("run the tests again"), .queued)
        XCTAssertEqual(queued, ["run the tests again"])
        XCTAssertTrue(started.isEmpty, "a live session was bypassed to start another one")
    }

    /// The live branch passes the mailbox's own answer through, whatever it was. A queue
    /// that had to drop its oldest sentence to take this one still says so.
    func testTheLiveTargetsOwnOutcomeIsPassedThrough() async {
        let router = InstructionRouter(
            enqueueToLiveTarget: { _ in .queuedDroppingOldest },
            startSession: { _, _ in .started(agentDisplayName: "Claude Code") }
        )

        XCTAssertEqual(router.route("also run the linter"), .queuedDroppingOldest)
    }

    /// Nothing live and nothing that could start anything. The refusal names both halves,
    /// because a wearer who heard only "nothing is running" would say it again, louder.
    func testWithNothingLiveAndNoLauncherTheSentenceIsRefusedOutLoud() async {
        let sink = RecordingSink()
        let router = InstructionRouter(
            enqueueToLiveTarget: { _ in nil },
            startSession: nil,
            diagnosticSink: sink
        )

        XCTAssertEqual(
            router.route("set up a Swift package for the parser"),
            .refused(spoken: "Nothing is running, and TapQ cannot start an agent here.")
        )
        XCTAssertEqual(sink.routedTo, ["refused"])
    }

    /// Nothing live, but TapQ can start something: the sentence becomes a session's goal.
    /// The whole point of the wake word — a machine with nothing running hears a sentence
    /// and there is work by the end of it.
    func testWithNothingLiveAndALauncherTheSentenceStartsASession() async {
        var started: [String] = []
        let router = InstructionRouter(
            enqueueToLiveTarget: { _ in nil },
            startSession: { goal, _ in
                started.append(goal)
                return .started(agentDisplayName: "Claude Code")
            }
        )

        XCTAssertEqual(
            router.route("set up a Swift package for the parser"),
            .startedSession(agentDisplayName: "Claude Code")
        )
        XCTAssertEqual(started, ["set up a Swift package for the parser"])
    }

    /// A launch that refused is not a launch that was never tried, and the wearer hears the
    /// launcher's own sentence rather than a generic one composed up here. Every refusal on
    /// this path is spoken (§1, rule 7), and the reason is the only part worth saying.
    func testALaunchRefusalCarriesItsOwnSentence() async {
        let sink = RecordingSink()
        let router = InstructionRouter(
            enqueueToLiveTarget: { _ in nil },
            startSession: { _, _ in
                .refused(spoken: OwnedSessionRefusal.workspaceUnwritable.spoken)
            },
            diagnosticSink: sink
        )

        XCTAssertEqual(
            router.route("set up a Swift package"),
            .refused(spoken: "I couldn't make a folder to start that in.")
        )
        XCTAssertEqual(sink.routedTo, ["start_refused"])
    }

    /// The closure a window takes is the same decision, so door 1 cannot drift from door 2.
    func testTheDictatingClosureIsTheSameDecision() async {
        let router = InstructionRouter(
            enqueueToLiveTarget: { _ in nil },
            startSession: { _, _ in .started(agentDisplayName: "Claude Code") }
        )
        let dictate: InstructionDictating = router.dictating

        XCTAssertEqual(dictate("build the parser"),
                       .startedSession(agentDisplayName: "Claude Code"))
    }

    // MARK: - Door 2, the loop's tool surface

    /// A started session is announced as a session. Both halves are said: the model is told
    /// what happened and told to be brief, and the wearer hears the sentence, because an
    /// agent started in their name while they are not watching has to be audible.
    func testDoorTwoAnnouncesAStartedSessionToBothAudiences() async {
        let output = InstructionRouter.toolOutput(
            for: .startedSession(agentDisplayName: "Claude Code"),
            instruction: "set up a Swift package",
            liveAgentDisplayName: nil
        )

        XCTAssertEqual(output.announce,
                       "Started a new Claude Code session: set up a Swift package")
        XCTAssertTrue(output.text.contains("nothing was live to receive it"), output.text)
    }

    /// A refusal is spoken once, in the sentence that refused, and the model is told not to
    /// say it again. Two versions of the same bad news is how a refusal stops sounding like
    /// one.
    func testDoorTwoSpeaksTheRefusalVerbatimAndTellsTheModelNotToRepeatIt() async {
        let output = InstructionRouter.toolOutput(
            for: .refused(spoken: InstructionRouter.nothingToReceiveRefusal),
            instruction: "set up a Swift package",
            liveAgentDisplayName: nil
        )

        XCTAssertEqual(output.announce, InstructionRouter.nothingToReceiveRefusal)
        XCTAssertTrue(output.text.contains("do not repeat the reason"), output.text)
    }

    /// And when it was queued after all, door 2 says what the named path says — it is the
    /// same delivery, and the wearer must not be able to hear which door it came through.
    func testDoorTwoAnnouncesAQueuedSentenceUnderTheAgentsName() async {
        let output = InstructionRouter.toolOutput(
            for: .queued,
            instruction: "run the tests again",
            liveAgentDisplayName: "Claude Code"
        )

        XCTAssertEqual(output.announce, "I've told Claude Code: run the tests again")
        XCTAssertTrue(output.text.contains("next turn boundary"), output.text)
    }

    /// A queue that dropped something says so out loud. The rule that put it there: a
    /// loop-composed instruction silently displacing one of the wearer's own is the
    /// review-flagged failure, and it does not stop being one on this door.
    func testDoorTwoSaysWhenTheQueueDroppedSomethingToTakeIt() async {
        let output = InstructionRouter.toolOutput(
            for: .queuedDroppingOldest,
            instruction: "run the tests again",
            liveAgentDisplayName: "Claude Code"
        )

        XCTAssertEqual(
            output.announce,
            "I've told Claude Code: run the tests again — the oldest waiting instruction "
                + "was dropped to make room."
        )
    }

    /// A mailbox that took nothing says nothing out loud: there is no news, only an absence,
    /// and the model has the sentence it needs to be honest in its own words.
    func testDoorTwoDoesNotAnnounceAMailboxThatTookNothing() async {
        let output = InstructionRouter.toolOutput(
            for: .notQueued,
            instruction: "run the tests again",
            liveAgentDisplayName: "Claude Code"
        )

        XCTAssertNil(output.announce)
        XCTAssertTrue(output.text.contains("nothing was queued"), output.text)
    }

    // MARK: - A name for the agent TapQ can start

    func testClaudeInAnyOfItsSpellingsNamesTheStartableAgent() async {
        for spoken in ["Claude", "claude code", "Claude Code", "Cloud", "cloud code", "Claude,"] {
            XCTAssertTrue(InstructionRouter.namesStartableAgent(spoken), spoken)
        }
    }

    func testCodexInItsSpellingsNamesTheOtherStartableAgent() async {
        for spoken in ["Codex", "codex", "Codex.", "codecs", "Kodex"] {
            XCTAssertEqual(InstructionRouter.startableAgent(named: spoken), .codex, spoken)
        }
        XCTAssertEqual(InstructionRouter.startableAgent(named: "Claude Code"), .claudeCode)
    }

    func testOtherNamesDoNotNameTheStartableAgent() async {
        for spoken in ["Cursor", "OpenCode", "it", "Claudia", "Codexy", ""] {
            XCTAssertFalse(InstructionRouter.namesStartableAgent(spoken), spoken)
            XCTAssertNil(InstructionRouter.startableAgent(named: spoken), spoken)
        }
    }

    /// The agent a name chose rides through to the launcher; a nameless route passes nil,
    /// which is the composition's cue to start its default.
    func testTheNamedAgentReachesTheLauncherAndANamelessRouteDoesNot() async {
        var agents: [AgentIdentity?] = []
        let router = InstructionRouter(
            enqueueToLiveTarget: { _ in nil },
            startSession: { _, agent in
                agents.append(agent)
                return .started(agentDisplayName: agent?.displayName ?? "default")
            }
        )

        XCTAssertEqual(router.route("build it", agent: .codex),
                       .startedSession(agentDisplayName: "Codex"))
        XCTAssertEqual(router.dictating(for: .codex)("lint it"),
                       .startedSession(agentDisplayName: "Codex"))
        XCTAssertEqual(router.route("test it"), .startedSession(agentDisplayName: "default"))
        XCTAssertEqual(agents, [.codex, .codex, nil])
    }

    /// A name bears only on what would be started: with something live, the sentence is
    /// queued there whatever the name was.
    func testANamedAgentDoesNotBypassALiveTarget() async {
        var started = 0
        let router = InstructionRouter(
            enqueueToLiveTarget: { _ in .queued },
            startSession: { _, _ in
                started += 1
                return .started(agentDisplayName: "Codex")
            }
        )
        XCTAssertEqual(router.route("run it", agent: .codex), .queued)
        XCTAssertEqual(started, 0)
    }
}
