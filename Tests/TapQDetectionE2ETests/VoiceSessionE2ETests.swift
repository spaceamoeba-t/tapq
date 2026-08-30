import Foundation
import XCTest
import TapQBrokerRuntime
import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
import TapQWireProtocol
@testable import TapQInteractionBaseline

/// Rung H leg 1 end to end: a Stop hook's wire message goes in, minutes pass, and the
/// sentence the wearer spoke comes back out as the reply that restarts the agent's turn.
///
/// The composition is the runtime's own — a real `BrokerServer` over a real wire message, a
/// real `InstructionWaitRegistry`, the real `StopQuestionCoordinator` draining the real
/// `InstructionMailbox` — with the ten-minute budget as the only thing substituted.
@MainActor
final class VoiceSessionE2ETests: XCTestCase {
    private static let session = "s1"

    /// The mirror pin for sweep finding F11's commit allowance.
    ///
    /// `WindowClock.commitAllowance` is the detector's hangover plus `WearerTurnCoordinator`'s
    /// endpoint delay — the two things that elapse between the wearer falling silent and
    /// their turn committing. The endpoint delay is read from its owner; the hangover cannot
    /// be, because it lives in `WearerSpeechConfig` and TapQInteractionBaseline depends only
    /// on TapQContracts. This target can see both, so the copy is checked here rather than
    /// left to drift the next time the capture study moves the number.
    func testTheWindowClockMirrorsTheDetectorHangover() async {
        XCTAssertEqual(WindowClock.detectorHangover,
                       WearerSpeechConfig().hangoverSeconds, accuracy: 0.0001,
                       "WindowClock.detectorHangover no longer matches WearerSpeechConfig")
        XCTAssertEqual(WindowClock.commitAllowance,
                       WearerSpeechConfig().hangoverSeconds
                           + WearerTurnCoordinator.defaultEndpointDelay,
                       accuracy: 0.0001)
    }

    private struct NeverAQuestion: ResponseQuestionClassifying {
        func classify(_ text: String) async -> ResponseQuestionClassification? { nil }
    }

    /// The runtime's own wiring of the wait arm, minus the microphone: anything already
    /// queued is delivered at once, otherwise the boundary is held until the registry says
    /// otherwise.
    private func makeServer(
        transport: InMemoryBrokerTransport,
        mailbox: InstructionMailbox,
        waits: InstructionWaitRegistry,
        memory: ConversationMemory
    ) -> BrokerServer {
        let coordinator = StopQuestionCoordinator(
            classifier: NeverAQuestion(),
            instructions: mailbox,
            recordInstruction: memory.instructionRecorder,
            suppressesLoopCap: true,
            runSelection: { _, _ in .noSelection },
            runApproval: { _, _ in .ask }
        )
        mailbox.onEnqueued = { [weak waits] session in
            waits?.noteInstructionQueued(session: session)
        }
        return BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onStopQuestion: { await coordinator.handle($0) },
            onInstructionWait: { waiting in
                if let ready = coordinator.deliverInstruction(
                    sessionID: waiting.sessionID, agent: waiting.agent
                ) {
                    if let lease = waiting.leaseID { waits.release(lease: lease) }
                    return .instruction(ready)
                }
                switch await waits.wait(
                    session: waiting.sessionID,
                    timeout: waiting.leaseID == nil
                        ? VoiceSessionBudget.brokerWait
                        : VoiceSessionBudget.brokerPoll,
                    lease: waiting.leaseID
                ) {
                case .instructionQueued:
                    return coordinator.deliverInstruction(
                        sessionID: waiting.sessionID, agent: waiting.agent
                    ).map { .instruction($0) } ?? .none
                case .renew:
                    return .renew
                case .timedOut, .released:
                    return .none
                }
            }
        )
    }

    private func patientWaits() -> InstructionWaitRegistry {
        InstructionWaitRegistry(sleep: { _ in try? await Task.sleep(for: .seconds(60)) })
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// The doorbell: the hook asks, nothing is queued, the wearer dictates two minutes
    /// later, and the wire answers with the instruction rather than with silence.
    func testAHeldBoundaryIsAnsweredWhenAnInstructionIsQueued() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = patientWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        let held = Task { try await transport.deliver(Data(Self.waitJSON.utf8)) }
        await settle()
        XCTAssertTrue(waits.isWaiting, "the boundary must still be open")

        // What a confirmed dictation does, from any of the three places one can arrive.
        mailbox.enqueue("also update the changelog", session: Self.session)

        let response = try JSONDecoder().decode(BrokerResponse.self, from: try await held.value)
        XCTAssertEqual(
            response,
            .instructionWait(
                instruction: "The user dictated a new instruction via TapQ hands-free: "
                    + "'also update the changelog'. Proceed accordingly."
            )
        )
        XCTAssertFalse(mailbox.hasPending(session: Self.session), "one drains per boundary")
        XCTAssertEqual(memory.events(session: Self.session).last?.kind, .instruction,
                       "and it is remembered as work handed over")
    }

    /// The instruction arrived before the boundary did — the wearer dictated while the agent
    /// was still working. The hook is answered without waiting at all.
    func testAnAlreadyQueuedInstructionIsAnsweredImmediately() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = patientWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        mailbox.enqueue("run the tests again", session: Self.session)
        let response = try JSONDecoder().decode(
            BrokerResponse.self, from: try await transport.deliver(Data(Self.waitJSON.utf8))
        )

        XCTAssertEqual(
            response,
            .instructionWait(
                instruction: "The user dictated a new instruction via TapQ hands-free: "
                    + "'run the tests again'. Proceed accordingly."
            )
        )
        XCTAssertFalse(waits.isWaiting, "nothing was ever held")
    }

    // MARK: - The renewable lease, over the wire

    /// A registry whose poll bound expires at once and whose lease grace does not: an
    /// afternoon of silence, compressed. Both sleeps are bounded.
    private func renewingWaits() -> InstructionWaitRegistry {
        InstructionWaitRegistry(sleep: { seconds in
            guard seconds != VoiceSessionBudget.brokerPoll else { return }
            try? await Task.sleep(for: .seconds(60))
        })
    }

    /// The decision, end to end: silence does not end a voice session. Five polls expire,
    /// the wire says `renew` to each, the boundary is still held — and the sentence spoken
    /// after all of them is still delivered to the agent that was waiting for it.
    func testSilenceRenewsTheBoundaryForeverAndTheInstructionStillArrives() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = renewingWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        for poll in 0..<5 {
            let response = try JSONDecoder().decode(
                BrokerResponse.self,
                from: try await transport.deliver(
                    Data(Self.leasedWaitJSON(request: "w\(poll)").utf8)
                )
            )
            XCTAssertEqual(response, .instructionWaitRenew, "poll \(poll)")
            XCTAssertTrue(waits.isWaiting, "the boundary survives its own poll expiring")
            XCTAssertEqual(waits.waitingCount, 1, "and is still one boundary, not five")
        }

        // The wearer finally says something — here, in the gap between two polls, which is
        // the harder half: there was no waiter to wake, so the next poll has to find it.
        mailbox.enqueue("also update the changelog", session: Self.session)
        let response = try JSONDecoder().decode(
            BrokerResponse.self,
            from: try await transport.deliver(Data(Self.leasedWaitJSON(request: "w5").utf8))
        )
        XCTAssertEqual(
            response,
            .instructionWait(
                instruction: "The user dictated a new instruction via TapQ hands-free: "
                    + "'also update the changelog'. Proceed accordingly."
            )
        )
        XCTAssertFalse(waits.isWaiting, "a delivered boundary is over")
    }

    /// And the ordinary half: the sentence arrives while a poll of the lease is parked, and
    /// that poll is the one answered.
    func testAnInstructionDuringALeasedPollIsDeliveredToIt() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = patientWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        let held = Task {
            try await transport.deliver(Data(Self.leasedWaitJSON(request: "w0").utf8))
        }
        await settle()
        XCTAssertTrue(waits.isWaiting)

        mailbox.enqueue("run the tests again", session: Self.session)

        let response = try JSONDecoder().decode(BrokerResponse.self, from: try await held.value)
        XCTAssertEqual(
            response,
            .instructionWait(
                instruction: "The user dictated a new instruction via TapQ hands-free: "
                    + "'run the tests again'. Proceed accordingly."
            )
        )
        XCTAssertFalse(waits.isWaiting, "a delivered boundary is over")
    }

    /// The wearer ended the session between two polls, which is the case a lease has to get
    /// right: there was nothing parked to answer, and the poll already on its way must be
    /// told the session is over rather than quietly re-opening it.
    func testAReleaseBetweenPollsIsNotUndoneByTheNextOne() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = renewingWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        _ = try await transport.deliver(Data(Self.leasedWaitJSON(request: "w0").utf8))
        XCTAssertTrue(waits.isWaiting)

        // A tap, a gesture, a broken voice channel, or shutdown — one call for all of them.
        waits.releaseAll()
        XCTAssertFalse(waits.isWaiting)

        let response = try JSONDecoder().decode(
            BrokerResponse.self,
            from: try await transport.deliver(Data(Self.leasedWaitJSON(request: "w1").utf8))
        )
        XCTAssertEqual(response, .instructionWait(instruction: nil))
        XCTAssertFalse(waits.isWaiting, "an ended session must not come back")
    }

    /// A shim from before renewable leases sends no `lease_id`, and the broker gives its
    /// request exactly the one-shot budget it was built against. Nothing about renewals
    /// reaches a peer that never asked for them.
    func testAPreLeaseShimKeepsTheOneShotBudget() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        // Impatient about everything: whatever budget this request is given, it expires.
        let waits = InstructionWaitRegistry(sleep: { _ in })
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        let response = try JSONDecoder().decode(
            BrokerResponse.self, from: try await transport.deliver(Data(Self.waitJSON.utf8))
        )
        XCTAssertEqual(response, .instructionWait(instruction: nil),
                       "never `renew` — the older shim would not know what to do with it")
        XCTAssertFalse(waits.isWaiting)
    }

    /// Ten minutes of silence, for a shim with no lease. The boundary goes, the Stop
    /// proceeds, and the session idles normally — a clean exit from the mode rather than a
    /// failure. This is the behavior a leased boundary deliberately no longer has.
    func testAnExpiredBudgetAnswersWithNoInstruction() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = InstructionWaitRegistry(sleep: { _ in })
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        let response = try JSONDecoder().decode(
            BrokerResponse.self, from: try await transport.deliver(Data(Self.waitJSON.utf8))
        )
        XCTAssertEqual(response, .instructionWait(instruction: nil))
    }

    /// The runtime is going away. It answers every held boundary on the way out rather than
    /// leaving a hook parked against a socket nobody will ever read.
    func testShutdownAnswersEveryHeldBoundary() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = patientWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()

        let held = Task { try await transport.deliver(Data(Self.waitJSON.utf8)) }
        await settle()
        XCTAssertTrue(waits.isWaiting)

        // What the runtime's `defer` does, in the order it does it.
        waits.releaseAll()
        server.stop()

        let response = try JSONDecoder().decode(BrokerResponse.self, from: try await held.value)
        XCTAssertEqual(response, .instructionWait(instruction: nil))
    }

    /// The wearer said "end voice session": the boundary is let go with nothing on it, and
    /// the queue is untouched because nothing was ever dictated.
    func testEndingTheSessionReleasesTheBoundaryWithNoInstruction() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = patientWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        let held = Task { try await transport.deliver(Data(Self.waitJSON.utf8)) }
        await settle()

        waits.release(session: Self.session)

        let response = try JSONDecoder().decode(BrokerResponse.self, from: try await held.value)
        XCTAssertEqual(response, .instructionWait(instruction: nil))
        XCTAssertFalse(waits.isWaiting)
    }

    /// A held boundary does not block the broker. An approval arriving while a session is
    /// parked is answered on its own terms, at once.
    func testAHeldBoundaryDoesNotBlockTheRestOfTheBroker() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = patientWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        let held = Task { try await transport.deliver(Data(Self.waitJSON.utf8)) }
        await settle()

        let approval = try JSONDecoder().decode(
            BrokerResponse.self,
            from: try await transport.deliver(Data(Self.approvalJSON.utf8))
        )
        XCTAssertEqual(approval, .decision(.ask, reason: nil),
                       "the approval was answered while a boundary was still held")

        waits.releaseAll()
        _ = try await held.value
    }

    /// A runtime with no voice session composed answers the wait the moment it arrives.
    /// A newer shim talking to it therefore behaves exactly like an older one.
    func testARuntimeWithoutAVoiceSessionNeverHoldsAnything() async throws {
        let transport = InMemoryBrokerTransport()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in }
        )
        try server.start()
        defer { server.stop() }

        let response = try JSONDecoder().decode(
            BrokerResponse.self, from: try await transport.deliver(Data(Self.waitJSON.utf8))
        )
        XCTAssertEqual(response, .instructionWait(instruction: nil))
    }

    /// The version gate: a peer that stamped v5 cannot have meant a v6 message, and a
    /// broker that accepted one would be reading a shape that peer never wrote.
    func testAWaitStampedWithAnOlderVersionIsRejected() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = patientWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        let response = try JSONDecoder().decode(
            BrokerResponse.self,
            from: try await transport.deliver(Data(Self.staleWaitJSON.utf8))
        )
        XCTAssertEqual(response, .error("protocol_version"))
        XCTAssertFalse(waits.isWaiting, "a rejected wait must not hold anything")
    }

    /// And the older messages a v5 shim does send still work against this runtime, which is
    /// the whole point of accepting the previous versions.
    func testAnOlderShimsStopQuestionStillWorks() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let waits = patientWaits()
        let transport = InMemoryBrokerTransport()
        let server = makeServer(
            transport: transport, mailbox: mailbox, waits: waits, memory: memory
        )
        try server.start()
        defer { server.stop() }

        mailbox.enqueue("ship it", session: Self.session)
        let response = try JSONDecoder().decode(
            BrokerResponse.self,
            from: try await transport.deliver(Data(Self.stopQuestionJSON.utf8))
        )
        XCTAssertEqual(
            response,
            .stopQuestion(reply: "The user dictated a new instruction via TapQ hands-free: "
                + "'ship it'. Proceed accordingly.")
        )
    }

    // MARK: - Fixtures

    /// What a Claude Stop hook sends when the runtime advertises a voice session.
    private static let waitJSON = """
        {"type":"instruction.wait","token":"tok","protocol_version":6,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","request_id":"w1"}
        """

    /// The same message from a shim running a renewable lease. `lease_id` is the only
    /// difference, and it is the whole of what makes the boundary outlive a poll.
    private static func leasedWaitJSON(request: String, lease: String = "L1") -> String {
        """
        {"type":"instruction.wait","token":"tok","protocol_version":6,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","request_id":"\(request)","lease_id":"\(lease)"}
        """
    }

    /// The same message from a shim that speaks the previous wire version.
    private static let staleWaitJSON = """
        {"type":"instruction.wait","token":"tok","protocol_version":5,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","request_id":"w1"}
        """

    private static let stopQuestionJSON = """
        {"type":"stop.question","token":"tok","protocol_version":5,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","text":"All done — the tests are green.","request_id":"q1"}
        """

    private static let approvalJSON = """
        {"type":"approval.request","token":"tok","protocol_version":6,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s2","tool_name":"Bash","tool_input":{},\
        "approval_source":"pre_tool_use","request_id":"r1"}
        """
}
