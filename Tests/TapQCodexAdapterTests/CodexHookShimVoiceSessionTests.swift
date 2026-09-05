import XCTest
@testable import TapQCodexAdapter
import TapQContracts
import TapQWireProtocol

/// The held turn boundary on the Codex side (RH1), ported from the Claude shim on
/// 2026-09-04 so a voice session behaves the same whichever agent is behind it.
///
/// The same narrow, safety-shaped claim: the hook waits only when a live runtime says it
/// will answer, it blocks the Stop only with text that runtime composed, and every other
/// outcome — no instruction, an error, an unreachable broker, a reply it cannot read —
/// lets the Stop proceed exactly as it always has.
final class CodexHookShimVoiceSessionTests: XCTestCase {
    private enum StubError: Error { case unreachable }

    /// A Stop event with no reply, so there is nothing to forward and the wait is the only
    /// thing left in the hook.
    private func stopInput(
        message: JSONValue = .null,
        active: Bool = false
    ) -> Data {
        try! JSONEncoder().encode([
            "hook_event_name": .string("Stop"),
            "session_id": .string("session-1"),
            "turn_id": .string("turn-1"),
            "transcript_path": .null,
            "cwd": .string("/tmp/project"),
            "model": .string("gpt-5.6"),
            "permission_mode": .string("default"),
            "stop_hook_active": .bool(active),
            "last_assistant_message": message,
        ] as [String: JSONValue])
    }

    private func blockReason(_ stdout: String?) throws -> String? {
        let obj = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data((stdout ?? "").utf8)
        )
        guard obj["decision"]?.stringValue == "block" else { return nil }
        return obj["reason"]?.stringValue
    }

    // MARK: - Only when the runtime says so

    func testAStopNeverWaitsUnlessTheRuntimeAdvertisesAVoiceSession() throws {
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stopInput()) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.notification])
    }

    /// The wait rides after the notification: that notification is what makes the runtime
    /// announce the turn ended, and the wearer hears "Codex finished" before "Listening."
    func testTheWaitIsSentAfterTheStopNotification() throws {
        var sentTypes: [String] = []
        _ = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return message["type"]?.stringValue == WireType.instructionWait
                ? BrokerResponse.instructionWait(instruction: nil).encoded()
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(sentTypes, [WireType.notification, WireType.instructionWait])
    }

    /// The wait names its agent and session and nothing policy-significant: no
    /// permission mode, no tool, no approval source. Its socket timeout is the voice-session
    /// one, sized to outlast the broker's poll.
    func testTheWaitCarriesTheCodexIdentityAndTheVoiceSessionTimeout() throws {
        var wait: [String: JSONValue]?
        var waitTimeout: TimeInterval?
        _ = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, timeout in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            wait = message
            waitTimeout = timeout
            return BrokerResponse.instructionWait(instruction: nil).encoded()
        }
        let sent = try XCTUnwrap(wait)
        XCTAssertEqual(sent["agent"]?.objectValue?["id"]?.stringValue, AgentIdentity.codex.id)
        XCTAssertEqual(sent["session_id"]?.stringValue, "session-1")
        XCTAssertNotNil(sent["lease_id"]?.stringValue)
        XCTAssertNil(sent["permission_mode"])
        XCTAssertNil(sent["tool_name"])
        XCTAssertEqual(waitTimeout, VoiceSessionBudget.shimSocketTimeout)
    }

    func testAnInstructionAnswerBlocksTheStopWithTheRuntimesOwnText() throws {
        let result = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            message["type"]?.stringValue == WireType.instructionWait
                ? BrokerResponse.instructionWait(instruction: "run the tests").encoded()
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try blockReason(result.stdout), "run the tests")
    }

    func testANoInstructionAnswerLetsTheStopProceed() throws {
        let result = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            message["type"]?.stringValue == WireType.instructionWait
                ? BrokerResponse.instructionWait(instruction: nil).encoded()
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    func testAnEmptyInstructionIsTreatedAsNoInstruction() throws {
        let result = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            message["type"]?.stringValue == WireType.instructionWait
                ? Data(#"{"wait":"instruction","instruction":""}"#.utf8)
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    func testABrokerErrorOrUnreadableReplyLetsTheStopProceed() throws {
        for reply in [#"{"error":"instruction_unavailable"}"#, "not json"] {
            let result = CodexHookShim.handle(
                stdinData: stopInput(),
                voiceSessionEnabled: { true }
            ) { message, _ in
                message["type"]?.stringValue == WireType.instructionWait
                    ? Data(reply.utf8)
                    : Data(#"{"ok":true}"#.utf8)
            }
            XCTAssertEqual(result, CodexHookShim.passThrough, reply)
        }
    }

    func testAnUnreachableBrokerLetsTheStopProceed() throws {
        let result = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            if message["type"]?.stringValue == WireType.instructionWait {
                throw StubError.unreachable
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    /// An answered question already carries the turn on, and holding it would put the
    /// wearer's next sentence behind an answer the agent has not read yet.
    func testAnAnsweredStopQuestionIsNeverAlsoHeldOpen() throws {
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(
            stdinData: stopInput(message: .string("Which approach? 1) A 2) B")),
            voiceSessionEnabled: { true }
        ) { message, _ in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            return type == WireType.stopQuestion
                ? Data(#"{"action":"answer","reply":"They chose A"}"#.utf8)
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(try blockReason(result.stdout), "They chose A")
        XCTAssertEqual(sentTypes, [WireType.stopQuestion])
    }

    /// The whole of the voice-session loop, on the turn after a delivered instruction:
    /// Codex marks that boundary `stop_hook_active`, and the reply on it is the result the
    /// wearer asked for. It is forwarded, and the boundary is held again for the next one.
    func testTheTurnAfterADeliveredInstructionIsForwardedAndHeldAgain() throws {
        var sentTypes: [String] = []
        var forwarded: String?
        let result = CodexHookShim.handle(
            stdinData: stopInput(message: .string("All 12 tests pass."), active: true),
            voiceSessionEnabled: { true }
        ) { message, _ in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            switch type {
            case WireType.stopQuestion:
                forwarded = message["text"]?.stringValue
                return Data(#"{"action":"pass"}"#.utf8)
            case WireType.instructionWait:
                return BrokerResponse.instructionWait(instruction: "now lint it").encoded()
            default:
                return Data(#"{"ok":true}"#.utf8)
            }
        }
        XCTAssertEqual(forwarded, "All 12 tests pass.")
        XCTAssertEqual(
            sentTypes, [WireType.stopQuestion, WireType.notification, WireType.instructionWait]
        )
        XCTAssertEqual(try blockReason(result.stdout), "now lint it")
    }

    /// The broker was unreachable for the stop question, so it is unreachable for the wait
    /// too. Trying anyway would spend another socket timeout discovering that.
    func testAnUnreachableStopQuestionSkipsTheWaitEntirely() throws {
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(
            stdinData: stopInput(message: .string("Should I deploy?")),
            voiceSessionEnabled: { true }
        ) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            throw StubError.unreachable
        }
        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.stopQuestion])
    }

    // MARK: - The renewable lease

    /// A clock that advances a full poll bound on every reading, so a stub that answers
    /// instantly still looks to the shim like a broker that waited.
    private func slowClock() -> () -> Date {
        var t = Date(timeIntervalSince1970: 0)
        return {
            defer { t = t.addingTimeInterval(VoiceSessionBudget.brokerPoll) }
            return t
        }
    }

    func testTheHookRepollsThroughEveryRenewalAndStillDelivers() throws {
        var waits = 0
        let result = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true },
            now: slowClock()
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            waits += 1
            return waits <= 5
                ? BrokerResponse.instructionWaitRenew.encoded()
                : BrokerResponse.instructionWait(instruction: "do the thing").encoded()
        }
        XCTAssertEqual(waits, 6, "five expired polls must not have ended the boundary")
        XCTAssertEqual(try blockReason(result.stdout), "do the thing")
    }

    /// Every poll of one hook invocation is the same held boundary, and says so. Without a
    /// stable lease the runtime would announce "Listening." once a minute forever.
    func testEveryPollCarriesOneLeaseAndAFreshRequestID() throws {
        var leases: [String] = []
        var requests: [String] = []
        var waits = 0
        _ = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true },
            now: slowClock()
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            waits += 1
            leases.append(message["lease_id"]?.stringValue ?? "")
            requests.append(message["request_id"]?.stringValue ?? "")
            return waits < 4
                ? BrokerResponse.instructionWaitRenew.encoded()
                : BrokerResponse.instructionWait(instruction: nil).encoded()
        }
        XCTAssertEqual(Set(leases).count, 1)
        XCTAssertFalse(leases[0].isEmpty)
        XCTAssertEqual(Set(requests).count, 4)
    }

    func testABrokerThatRenewsInstantlyDoesNotSpinForever() throws {
        var waits = 0
        let frozen = Date(timeIntervalSince1970: 0)
        let result = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true },
            now: { frozen }
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            waits += 1
            return BrokerResponse.instructionWaitRenew.encoded()
        }
        XCTAssertEqual(waits, CodexHookShim.fastRenewLimit)
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    func testAnUnreachableBrokerMidLeaseEndsTheLoop() throws {
        var waits = 0
        let result = CodexHookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true },
            now: slowClock()
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            waits += 1
            if waits == 3 { throw StubError.unreachable }
            return BrokerResponse.instructionWaitRenew.encoded()
        }
        XCTAssertEqual(waits, 3)
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }
}
