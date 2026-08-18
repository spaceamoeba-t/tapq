import Foundation
import XCTest
import TapQBrokerRuntime
import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
import TapQWireProtocol
@testable import TapQInteractionBaseline

/// Rung C end to end: a sentence the wearer says out loud reaches an agent's session as
/// bytes on the wire, and a sentence anybody else says does not.
///
/// The composition is the runtime's own, minus the microphone and the IMU. The grammar is
/// the real `VoiceCommandMatcher`, the attribution answer comes from a real
/// `WearerSpeechMonitor` driven by a synthetic jerk envelope, the confirmation is a
/// generated nod through the real pipeline, the queue is the runtime's
/// `InstructionMailbox`, and the delivery is the real `StopQuestionCoordinator` answering
/// a real `BrokerServer` over a real wire message.
@MainActor
final class InstructionPathE2ETests: XCTestCase {
    private static let session = "s1"

    private func request(summary: String = "run npm test") -> ApprovalRequest {
        ApprovalRequest(
            id: "r1", sessionID: Self.session, agent: .claudeCode, toolName: "Bash",
            summary: summary, detail: "npm test"
        )
    }

    /// The whole rung in one test: dictate, confirm, queue, deliver.
    ///
    /// The wearer says "tell it to run the tests again" into an open approval window; the
    /// IMU says the wearer said it; a nod confirms the read-back; and when the agent's turn
    /// ends, the stop question it sends over the wire comes back carrying the instruction
    /// instead of an answer. The approval it was all spoken inside is still waiting
    /// afterwards, and still resolves.
    func testAttributedDictationIsDeliveredAtTheNextTurnBoundaryWireToWire() async throws {
        let clock = StreamClock()
        let monitor = WearerSpeechMonitor(monotonicNow: { clock.now })
        let signal = MonitorSpeechSignal(monitor: monitor)
        let gate = GateBox()
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let harness = DetectionPathHarness(
            voiceGate: { channel, sink in
                let composed = WearerGatedVoice(
                    wrapping: channel, signal: signal,
                    monotonicNow: { clock.now }, diagnosticSink: sink
                )
                gate.gate = composed
                return composed
            },
            recallResponder: memory.recallResponder,
            instructionCapability: memory.instructionCapability,
            wearerAttribution: { gate.gate?.isWearerAttributedNow ?? false },
            instructionEnqueue: memory.instructionEnqueue
        )

        let approval = request()
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
        XCTAssertTrue(opened, "the approval opened no input window")

        // The wearer speaks, and stops. The recognizer's match lands inside the trailing
        // attribution window, which is the ordinary case on real hardware.
        var cursor = TraceGenerators.epoch
        cursor = stream(TraceGenerators.speechEnvelope(startingAt: cursor),
                        into: monitor, clock: clock)
        cursor = stream(TraceGenerators.restingJitter(startingAt: cursor, duration: 1.0),
                        into: monitor, clock: clock)
        XCTAssertTrue(signal.isSignalAvailable, "a quiet wearer is not an absent signal")

        harness.hear("tell it to run the tests again")

        let readBackWindow = await harness.waitForWindow(2)
        XCTAssertTrue(readBackWindow, "the read-back must re-listen")
        XCTAssertTrue(
            harness.speech.said("Instruction: 'run the tests again.' Nod or say yes to queue it."),
            "the wearer must hear what the agent is about to be told: "
                + "\(harness.speech.spoken.map(\.text))"
        )
        XCTAssertTrue(mailbox.pending(session: Self.session).isEmpty,
                      "nothing may be queued before the wearer confirms it")

        // The nod that confirms the read-back. It is spent inside the dictation flow: the
        // approval below is still unresolved when it is over.
        harness.feed(TraceGenerators.doubleNod())
        let resumed = await harness.waitForWindow(3)
        XCTAssertTrue(resumed, "queueing must resume the window")
        XCTAssertTrue(harness.speech.said("Queued for Claude Code."))
        XCTAssertEqual(mailbox.pending(session: Self.session).map(\.text),
                       ["run the tests again"])

        // Asked now, the status line says an instruction is waiting.
        harness.hear("who's waiting")
        let statusWindow = await harness.waitForWindow(4)
        XCTAssertTrue(statusWindow)
        XCTAssertTrue(
            harness.speech.said("Claude Code: run npm test. Nothing else waiting. "
                + "1 instruction queued."),
            "status spoke: \(harness.speech.spoken.map(\.text))"
        )

        // The approval the wearer was asked about is untouched, and answering it is what
        // ends the window — the dictation never resolved anything.
        harness.feed(TraceGenerators.doubleShake())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny, "dictation must never resolve the request")

        // The turn boundary, on the wire. The coordinator is composed exactly as the
        // runtime composes it, over the same mailbox the dictation filled.
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
                + "'run the tests again'. Proceed accordingly."),
            "the boundary must carry the instruction, not an answer"
        )
        XCTAssertTrue(mailbox.pending(session: Self.session).isEmpty,
                      "one instruction drains per boundary")
        // And it is remembered as work handed over, never as work done.
        XCTAssertEqual(memory.events(session: Self.session).last?.kind, .instruction)
    }

    /// The fail-closed inversion, from both sides.
    ///
    /// (a) The signal cannot say who spoke. The *approval* gate fails open on purpose —
    /// the command reaches the controller exactly as it always has — and the dictation
    /// path refuses it anyway, out loud, with `instruction.rejected_unattributed`.
    /// (b) Somebody else in the room says the same sentence with a live signal. The gate
    /// drops it before the controller ever hears it.
    ///
    /// Either way nothing is queued, and the wearer's own request is still waiting.
    func testUnattributedDictationIsRefusedAndQueuesNothing() async throws {
        let clock = StreamClock()
        let monitor = WearerSpeechMonitor(monotonicNow: { clock.now })
        let signal = MonitorSpeechSignal(monitor: monitor)
        let gate = GateBox()
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let harness = DetectionPathHarness(
            voiceGate: { channel, sink in
                let composed = WearerGatedVoice(
                    wrapping: channel, signal: signal,
                    monotonicNow: { clock.now }, diagnosticSink: sink
                )
                gate.gate = composed
                return composed
            },
            instructionCapability: memory.instructionCapability,
            wearerAttribution: { gate.gate?.isWearerAttributedNow ?? false },
            instructionEnqueue: memory.instructionEnqueue
        )

        let approval = request()
        let decision = Task {
            await memory.withWindow(
                sessionID: approval.sessionID,
                agent: approval.agent,
                summary: approval.summary
            ) {
                await harness.interaction.resolve(approval)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        // (a) AirPods asleep: no samples, so the signal is stale and cannot answer.
        clock.now += monitor.stalenessHorizon + 1.0
        XCTAssertFalse(signal.isSignalAvailable)

        harness.hear("tell it to delete the production database")

        let refusalWindow = await harness.waitForWindow(2)
        XCTAssertTrue(refusalWindow, "a refusal must re-listen, not resolve")
        XCTAssertTrue(
            harness.speech.said("I can't confirm that was you — instruction discarded."),
            "spoke: \(harness.speech.spoken.map(\.text))"
        )
        let refusals = harness.diagnostics.events.filter {
            $0.name == "instruction.rejected_unattributed"
        }
        XCTAssertEqual(refusals.count, 1, "the refusal must be diagnosable")
        XCTAssertEqual(refusals.first?.fields["stage"], "begin",
                       "turned away at the door, before the wearer is invited to speak")
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.passed_signal_unavailable"
        }, "the approval gate must still be failing open — only instructions fail closed")
        XCTAssertTrue(mailbox.pending(session: Self.session).isEmpty)

        // (b) A live signal and a voice that is not the wearer's: dropped at the gate.
        // The stream resumes from where the clock already is — a monitor fed timestamps
        // that run backwards is not a state any headphone can produce, and it would leave
        // the detector wedged mid-utterance rather than testing anything.
        var cursor = clock.now + TraceGenerators.sampleInterval
        cursor = stream(TraceGenerators.speechEnvelope(startingAt: cursor),
                        into: monitor, clock: clock)
        cursor = stream(TraceGenerators.restingJitter(startingAt: cursor, duration: 5.0),
                        into: monitor, clock: clock)
        XCTAssertTrue(signal.isSignalAvailable, "a quiet wearer is not an absent signal")

        harness.hear("tell it to delete the production database")

        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.rejected_nonwearer"
        }, "a bystander's dictation must not even reach the controller")
        XCTAssertTrue(mailbox.pending(session: Self.session).isEmpty)
        XCTAssertEqual(harness.inputs.openedWindows, 2,
                       "the dropped command must not re-listen")

        harness.feed(TraceGenerators.doubleNod())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow, "the wearer's own request still answers normally")
    }

    /// Without `--voice-instructions` the grammar still hears the phrase and it reaches
    /// nowhere: nothing spoken, nothing queued, nothing diagnosed, and the window resolves
    /// as it always did.
    ///
    /// It costs one silent re-listen, which is the same shape every informational intent
    /// has when nobody is composed to answer it — a free-form transcript without a
    /// responder does exactly this. What must not happen is a spoken word, a queued
    /// sentence, or a resolved request.
    func testWithoutTheFlagTheDictationGrammarIsInert() async {
        let harness = DetectionPathHarness()
        let approval = request()
        let decision = Task { await harness.interaction.resolve(approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)
        let spokenBefore = harness.speech.spoken.count

        harness.hear("tell it to run the tests again")
        // Give an enqueue that should not exist every chance to happen.
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(harness.speech.spoken.count, spokenBefore,
                       "an inert grammar says nothing: \(harness.speech.spoken.map(\.text))")
        XCTAssertFalse(harness.diagnostics.events.contains {
            $0.name.hasPrefix("instruction.")
        })

        harness.feed(TraceGenerators.doubleNod())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
        XCTAssertEqual(harness.inputs.openedWindows, 2,
                       "one silent re-listen and no more — the phrase resolved nothing")
    }

    // MARK: - Fixtures

    /// The wire message a Claude stop hook sends at the end of a turn.
    private static let stopQuestionJSON = """
        {"type":"stop.question","token":"tok","protocol_version":5,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","text":"All done — the tests are green.","request_id":"q1"}
        """

    /// The classifier that finds no question in the agent's reply, which is what makes the
    /// delivered instruction unambiguously the instruction path's doing: with nothing to
    /// answer, the only reply this boundary can produce is the queued sentence.
    private struct NeverAQuestion: ResponseQuestionClassifying {
        func classify(_ text: String) async -> ResponseQuestionClassification? { nil }
    }

    /// Holds the gate the harness composes, so the dictation path can ask it the
    /// fail-closed question. The runtime does the same thing with a local `var`.
    private final class GateBox {
        var gate: WearerGatedVoice?
    }

    /// The monotonic clock the monitor and the gate both read.
    private final class StreamClock {
        var now: TimeInterval = TraceGenerators.epoch
    }

    private func stream(_ trace: [HeadMotionSample],
                        into monitor: WearerSpeechMonitor,
                        clock: StreamClock) -> TimeInterval {
        for sample in trace {
            clock.now = sample.timestamp
            monitor.ingest(sample)
        }
        return (trace.last?.timestamp ?? clock.now) + TraceGenerators.sampleInterval
    }
}
