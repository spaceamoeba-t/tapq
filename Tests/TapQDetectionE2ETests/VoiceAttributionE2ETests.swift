import Foundation
import XCTest
import TapQBrokerRuntime
import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
import TapQWireProtocol
@testable import TapQInteractionBaseline

/// Per-utterance attribution, end to end: the same sentence, said in three different
/// worlds, reaching two gates that are required to disagree about it.
///
/// `WearerPathE2ETests` owns the detector — whether a jerk envelope reads as wearer speech
/// is its question, and it answers it with a real `WearerSpeechMonitor`. This file owns the
/// layer above: given a verdict about *this* utterance, does the command channel fail open
/// while the instruction channel fails closed, does a bystander get stopped before the
/// controller ever hears them, and does an attributed dictation survive all the way to an
/// agent's session as bytes on the wire.
///
/// Which is why the verdict is scripted rather than played in on an envelope. "This
/// utterance, unattributed" is a sentence an envelope cannot say — it can only be quiet,
/// stale, or absent, each of which also says a great deal about thresholds this file has no
/// business pinning. Everything downstream of the verdict is the shipping stack: the real
/// grammar, the real `WearerGatedVoice` and its two deliberately-duplicated readings, the
/// real `InstructionDictation`, the runtime's own mailbox, and a real `BrokerServer`.
@MainActor
final class VoiceAttributionE2ETests: XCTestCase {
    private static let session = "s1"

    // MARK: - The invariant pair, in one signal state

    /// The fail-open/fail-closed split, asserted where it is hardest to fake: one window,
    /// one signal state, two utterances that must be treated oppositely.
    ///
    /// The signal cannot say who spoke — earbuds asleep, no motion stream, a stale sample.
    /// A dictation is refused out loud and queues nothing, because a runtime that cannot
    /// attribute speech has no business putting words in an agent's mouth. A spoken "yes"
    /// in the very same state still resolves the approval, because attribution may only
    /// ever remove commands it is confident about and never invent a new way for a window
    /// to hang.
    ///
    /// The two claims are one test on purpose. Split apart, either half could keep passing
    /// while the signal quietly changed underneath it; together, the only way both pass is
    /// if the two gates really did read the same verdict and draw opposite conclusions.
    func testOneUnavailableSignalRefusesDictationAndStillTakesTheYes() async throws {
        var dictated: [String] = []
        let harness = DetectionPathHarness(
            instructionCapability: { true },
            instructionEnqueue: { dictated.append($0); return .queued },
            attribution: .signalUnavailable
        )

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")

        // The instruction half: turned away at the door, before the wearer is ever invited
        // to dictate a sentence.
        harness.hear("tell it to delete the production database",
                     attributed: .signalUnavailable)

        let refusalWindow = await harness.waitForWindow(2)
        XCTAssertTrue(refusalWindow, "a refusal must re-listen, never resolve")
        XCTAssertTrue(
            harness.speech.said("I can't confirm that was you — instruction discarded."),
            "a refused dictation must be audible; silence reads as success. spoke: "
                + "\(harness.speech.spoken.map(\.text))"
        )
        let refusals = harness.diagnostics.events.filter {
            $0.name == "instruction.rejected_unattributed"
        }
        XCTAssertEqual(refusals.count, 1, "the refusal must be diagnosable")
        XCTAssertEqual(refusals.first?.fields["stage"], "begin")
        XCTAssertTrue(dictated.isEmpty, "an unattributable voice queued: \(dictated)")

        // The command half, same window and same signal: through, exactly as it travelled
        // before attribution existed.
        harness.hear("yes", attributed: .signalUnavailable)

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow, "commands must fail open on an unavailable signal")
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.passed_signal_unavailable"
        }, "the fail-open pass must be diagnosable too")
        XCTAssertTrue(dictated.isEmpty, "an approval must not queue anything")
    }

    // MARK: - The non-wearer variants of the same pair

    /// A live signal that says somebody else is talking: both halves stop at the gate, and
    /// they stop *earlier* than the unavailable-signal pair above.
    ///
    /// That difference is the assertion. An unattributable dictation reaches the controller
    /// and is refused there, which costs a spoken sentence and a re-listen. A bystander's
    /// never arrives: no word is spoken, no window is re-opened, and the controller cannot
    /// tell the room went quiet from the room saying "delete the production database". The
    /// wearer's own "yes", one utterance later in the same window, still answers.
    func testABystandersDictationAndYesBothStopAtTheGate() async throws {
        var dictated: [String] = []
        let harness = DetectionPathHarness(
            instructionCapability: { true },
            instructionEnqueue: { dictated.append($0); return .queued },
            attribution: .wearer
        )

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)
        let spokenAfterPrompt = harness.speech.spoken.count

        // (a) Somebody else dictates. The controller never learns that it happened.
        harness.hear("tell it to delete the production database", attributed: .bystander)

        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.rejected_nonwearer"
        }, "a bystander's dictation must not reach the controller")
        XCTAssertFalse(harness.diagnostics.events.contains {
            $0.name.hasPrefix("instruction.")
        }, "a dictation dropped at the gate never opened a flow to refuse")
        XCTAssertTrue(dictated.isEmpty)
        XCTAssertEqual(harness.speech.spoken.count, spokenAfterPrompt,
                       "a dropped command is silent: \(harness.speech.spoken.map(\.text))")

        // (b) The same voice answers the question instead. Also dropped, and the window is
        // still the one window the approval opened.
        harness.hear("yes", attributed: .bystander)

        XCTAssertEqual(harness.inputs.openedWindows, 1,
                       "neither dropped command may re-listen")
        XCTAssertEqual(harness.diagnostics.events.filter {
            $0.name == "command.rejected_nonwearer"
        }.count, 2)

        // (c) The wearer, in the same window, and the prompt is answered.
        harness.hear("yes", attributed: .wearer)

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
        XCTAssertTrue(dictated.isEmpty, "nothing in this test was ever dictatable")
    }

    // MARK: - Attributed dictation, all the way to the wire

    /// The whole attributed path in one test: open the flow with no text, hear the cue,
    /// dictate, hear it read back, confirm it, and find it on the wire at the next turn
    /// boundary.
    ///
    /// Every utterance in here carries its own wearer verdict, and two of them are checked
    /// independently by the flow — opening dictation does not make the next voice in the
    /// room the wearer's, so the sentence earns its own attribution check after the cue.
    /// The confirming "yes" is spent inside the flow: the approval it was all spoken inside
    /// is answered afterwards by a shake, and it denies, which it could not do if the "yes"
    /// had leaked into the allow path.
    func testAttributedDictationReachesTheTurnBoundaryWireToWire() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let harness = DetectionPathHarness(
            instructionCapability: memory.instructionCapability,
            instructionEnqueue: memory.instructionEnqueue,
            attribution: .wearer
        )

        let approval = Self.approval
        let decision = Task {
            await memory.withWindow(
                sessionID: approval.sessionID,
                agent: approval.agent,
                summary: approval.summary,
                detail: approval.detail
            ) {
                await harness.interaction.resolve(approval)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        // Opened without text: the wearer said they want to instruct the agent and has not
        // yet said what.
        harness.hear("new instruction", attributed: .wearer)

        let cueWindow = await harness.waitForWindow(2)
        XCTAssertTrue(cueWindow, "the cue must open a turn for the sentence")
        XCTAssertTrue(harness.speech.said("Go ahead."),
                      "spoke: \(harness.speech.spoken.map(\.text))")

        // The sentence itself. Free text inside the flow is the instruction, never a
        // question, and it is a second utterance with a verdict of its own.
        harness.apply(.wearer)
        harness.hearFreeform(Self.instruction)

        let readBackWindow = await harness.waitForWindow(3)
        XCTAssertTrue(readBackWindow, "the read-back must re-listen")
        XCTAssertTrue(
            harness.speech.said("Instruction: '\(Self.instruction).' "
                + "Nod or say yes to queue it."),
            "the wearer must hear what the agent is about to be told: "
                + "\(harness.speech.spoken.map(\.text))"
        )
        XCTAssertTrue(mailbox.pending(session: Self.session).isEmpty,
                      "nothing may be queued before the wearer confirms it")

        harness.hear("yes", attributed: .wearer)

        let resumed = await harness.waitForWindow(4)
        XCTAssertTrue(resumed, "queueing must resume the window")
        XCTAssertTrue(harness.speech.said("Queued for Claude Code."))
        XCTAssertEqual(mailbox.pending(session: Self.session).map(\.text),
                       [Self.instruction])

        // The request is still on the table, and answering it is what ends the window.
        harness.feed(TraceGenerators.doubleShake())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny,
                       "the yes that confirmed the read-back must not have approved anything")

        // The turn boundary, on the wire. The coordinator is composed as the runtime
        // composes it, over the same mailbox the dictation filled, and the classifier finds
        // no question — so the only reply this boundary can produce is the queued sentence.
        let coordinator = StopQuestionCoordinator(
            classifier: NeverAQuestion(),
            instructions: mailbox,
            recordInstruction: memory.instructionRecorder,
            runSelection: { _, _ in .noSelection },
            runApproval: { _, _ in .ask }
        )
        let transport = InMemoryBrokerTransport()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onStopQuestion: { await coordinator.handle($0) }
        )
        try server.start()
        defer { server.stop() }

        let responseData = try await transport.deliver(Data(Self.stopQuestionJSON.utf8))
        let response = try JSONDecoder().decode(BrokerResponse.self, from: responseData)
        XCTAssertEqual(
            response,
            .stopQuestion(reply: "The user dictated a new instruction via TapQ hands-free: "
                + "'\(Self.instruction)'. Proceed accordingly."),
            "the boundary must carry the wearer's sentence, not an answer"
        )
        XCTAssertTrue(mailbox.pending(session: Self.session).isEmpty,
                      "one instruction drains per boundary")
        XCTAssertEqual(memory.events(session: Self.session).last?.kind, .instruction,
                       "it is remembered as work handed over, never as work done")
    }

    // MARK: - Fixtures

    /// A sentence of ordinary English that the grammar knows no word of, so it can only
    /// arrive as free text. Dictation collides with the grammar easily — "run the tests
    /// again" is a repeat, "explain the diff" is a details — and a collision here would be
    /// testing the matcher rather than the attribution path.
    private static let instruction = "update the changelog before you push"

    private static let approval = ApprovalRequest(
        id: "r1", sessionID: session, agent: .claudeCode, toolName: "Bash",
        summary: "run npm test", detail: "npm test"
    )

    /// The wire message a Claude stop hook sends at the end of a turn.
    private static let stopQuestionJSON = """
        {"type":"stop.question","token":"tok","protocol_version":5,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","text":"All done — the tests are green.","request_id":"q1"}
        """

    private struct NeverAQuestion: ResponseQuestionClassifying {
        func classify(_ text: String) async -> ResponseQuestionClassification? { nil }
    }
}
