import XCTest
@testable import TapQClaudeAdapter
import TapQWireProtocol
import TapQContracts

/// The held turn boundary, from the shim's side (RH1).
///
/// The claim under test is narrow and safety-shaped: the hook waits only when a live
/// runtime says it will answer, it blocks the Stop only with text that runtime composed,
/// and every other outcome — no instruction, an error, an unreachable broker, a reply it
/// cannot read — lets the Stop proceed exactly as it always has. A voice session that goes
/// wrong has to end as "the mode stopped", never as "the terminal is stuck".
final class HookShimVoiceSessionTests: XCTestCase {
    private enum StubError: Error { case unreachable }

    private func stdin(_ json: String) -> Data { Data(json.utf8) }

    /// A Stop event whose transcript holds no question, so the stop-question path passes
    /// and the wait is the only thing left in the hook.
    private func stopInput() -> Data {
        stdin(#"{"hook_event_name":"Stop","session_id":"s1"}"#)
    }

    /// Writes a one-reply transcript fixture and returns its path.
    private func transcript(_ assistantText: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-voicesession-\(UUID().uuidString).jsonl")
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(assistantText)"}]}}"#
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func blockReason(_ stdout: String?) throws -> String? {
        let obj = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data((stdout ?? "").utf8)
        )
        guard obj["decision"]?.stringValue == "block" else { return nil }
        return obj["reason"]?.stringValue
    }

    // MARK: - Only when the runtime says so

    /// The default, and every run without `--voice-session`: the Stop notifies and returns,
    /// and no socket is opened to find out whether anyone wanted it to wait.
    func testAStopNeverWaitsUnlessTheRuntimeAdvertisesAVoiceSession() throws {
        var sentTypes: [String] = []
        let result = HookShim.handle(stdinData: stopInput()) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(sentTypes, ["notification.event"])
    }

    /// The wait rides after the notification, deliberately: that notification is what makes
    /// the runtime announce the turn ended, and the wearer hears "Claude Code finished"
    /// before they hear "Listening."
    func testTheWaitIsSentAfterTheStopNotification() throws {
        var sentTypes: [String] = []
        var waitTimeout: TimeInterval?
        _ = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, timeout in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            if type == WireType.instructionWait {
                waitTimeout = timeout
                XCTAssertEqual(message["session_id"]?.stringValue, "s1")
                XCTAssertEqual(message["protocol_version"]?.intValue, WireProtocol.version)
                XCTAssertEqual(message["agent"]?["id"]?.stringValue, "claude-code")
                XCTAssertFalse(message["request_id"]?.stringValue?.isEmpty ?? true)
                return Data(#"{"wait":"none"}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(sentTypes, ["notification.event", WireType.instructionWait])
        XCTAssertEqual(waitTimeout, HookShim.instructionWaitTimeout)
        XCTAssertGreaterThan(HookShim.instructionWaitTimeout, VoiceSessionBudget.brokerPoll,
                             "the socket must outlast the poll the broker is running")
    }

    /// The wait carries identity and nothing else. There is no field on it a decision could
    /// be steered by, which is what makes "the reply is text the wearer confirmed" a
    /// property of the message rather than of the handler.
    func testTheWaitCarriesNothingPolicySignificant() throws {
        var captured: [String: JSONValue]?
        _ = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            if message["type"]?.stringValue == WireType.instructionWait { captured = message }
            return Data(#"{"wait":"none"}"#.utf8)
        }
        let message = try XCTUnwrap(captured)
        for forbidden in ["tool_name", "tool_input", "cwd", "permission_mode",
                          "approval_source", "text"] {
            XCTAssertNil(message[forbidden], "\(forbidden) must not ride a wait")
        }
    }

    // MARK: - What comes back

    /// The delivery: the broker's instruction becomes the Stop block's reason, verbatim.
    /// The shim writes none of that sentence — what reaches Claude is what the wearer heard
    /// read back to them.
    func testAnInstructionAnswerBlocksTheStopWithTheRuntimesOwnText() throws {
        let reply = "The user dictated a new instruction via TapQ hands-free: "
            + "'run the tests again'. Proceed accordingly."
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            let encoded = BrokerResponse.instructionWait(instruction: reply).encoded()
            return encoded
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try blockReason(result.stdout), reply)
        let obj = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data((result.stdout ?? "").utf8)
        )
        XCTAssertNil(obj["hookSpecificOutput"],
                     "Stop block output is top-level, not wrapped")
    }

    /// The budget expired, or the wearer ended the session. Both look the same here and
    /// both mean the same thing: carry on.
    func testANoInstructionAnswerLetsTheStopProceed() throws {
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            message["type"]?.stringValue == WireType.instructionWait
                ? Data(#"{"wait":"none"}"#.utf8)
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testAnEmptyInstructionIsTreatedAsNoInstruction() throws {
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            message["type"]?.stringValue == WireType.instructionWait
                ? Data(#"{"wait":"instruction","instruction":""}"#.utf8)
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout, "an empty block reason would restart the turn with nothing")
    }

    func testABrokerErrorLetsTheStopProceed() throws {
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            message["type"]?.stringValue == WireType.instructionWait
                ? Data(#"{"error":"protocol_version"}"#.utf8)
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
    }

    /// A runtime that died while the hook was parked, or a socket that was never there.
    /// The hook has to come back on its own rather than hold the session.
    func testAnUnreachableBrokerLetsTheStopProceed() throws {
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            throw StubError.unreachable
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testAnUnreadableReplyLetsTheStopProceed() throws {
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true }
        ) { message, _ in
            message["type"]?.stringValue == WireType.instructionWait
                ? Data("not json".utf8)
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
    }

    // MARK: - Interaction with the stop-question path

    /// An answered question already carries the turn on, so there is nothing to hold open —
    /// and holding one would put the wearer's next sentence behind an answer the agent has
    /// not read yet.
    func testAnAnsweredStopQuestionIsNeverAlsoHeldOpen() throws {
        let path = try transcript("Which approach? 1) A 2) B")
        var sentTypes: [String] = []
        let result = HookShim.handle(
            stdinData: stdin(#"{"hook_event_name":"Stop","session_id":"s1","permission_mode":"default","transcript_path":"\#(path)"}"#),
            voiceSessionEnabled: { true }
        ) { message, _ in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            return type == WireType.stopQuestion
                ? Data(#"{"action":"answer","reply":"They chose A"}"#.utf8)
                : Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(try blockReason(result.stdout), "They chose A")
        XCTAssertEqual(sentTypes, [WireType.stopQuestion],
                       "an answered question neither notifies nor waits")
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

    /// The decision, from the shim's side: a boundary is not ended by a poll expiring. Five
    /// renewals in a row and the hook is still parked; the sixth answer delivers.
    func testTheHookRepollsThroughEveryRenewalAndStillDelivers() throws {
        var waits = 0
        let result = HookShim.handle(
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
        _ = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true },
            now: slowClock()
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            leases.append(message["lease_id"]?.stringValue ?? "")
            requests.append(message["request_id"]?.stringValue ?? "")
            waits += 1
            return waits < 3
                ? BrokerResponse.instructionWaitRenew.encoded()
                : Data(#"{"wait":"none"}"#.utf8)
        }
        XCTAssertEqual(leases.count, 3)
        XCTAssertEqual(Set(leases).count, 1, "one boundary, one lease")
        XCTAssertFalse(leases[0].isEmpty)
        XCTAssertEqual(Set(requests).count, 3, "but each poll is its own request")
    }

    /// The wearer ended the session, the voice channel broke, or the runtime is going away.
    /// A renewal is the only answer that means "come back" — everything else lets the Stop
    /// proceed on the spot, however many renewals preceded it.
    func testAReleaseAfterRenewalsEndsTheLoopAtOnce() throws {
        var waits = 0
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true },
            now: slowClock()
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            waits += 1
            return waits < 4
                ? BrokerResponse.instructionWaitRenew.encoded()
                : BrokerResponse.instructionWait(instruction: nil).encoded()
        }
        XCTAssertEqual(waits, 4)
        XCTAssertNil(result.stdout)
    }

    /// A runtime that dies mid-session: the next poll cannot connect, and the hook comes
    /// back rather than re-polling a socket nobody is listening on.
    func testAnUnreachableBrokerMidLeaseEndsTheLoop() throws {
        var waits = 0
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true },
            now: slowClock()
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            waits += 1
            if waits < 3 { return BrokerResponse.instructionWaitRenew.encoded() }
            throw StubError.unreachable
        }
        XCTAssertEqual(waits, 3)
        XCTAssertNil(result.stdout)
    }

    /// The spin guard, and the only reason the loop is not literally `while true`: a broker
    /// that renews without ever having waited is confused, and a hook that answered it
    /// forever would burn a core for as long as the terminal stayed open.
    func testABrokerThatRenewsInstantlyDoesNotSpinForever() throws {
        var waits = 0
        // A clock that never advances: every renewal comes back in no time at all.
        let frozen = Date(timeIntervalSince1970: 0)
        let result = HookShim.handle(
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
        XCTAssertEqual(waits, HookShim.fastRenewLimit)
        XCTAssertNil(result.stdout, "and it still ends as a pass-through, never a stall")
    }

    /// The guard counts *consecutive* fast renewals, so a session that is renewing honestly
    /// is never cut short by one quick round trip.
    func testAnHonestPollResetsTheSpinGuard() throws {
        var waits = 0
        var t = Date(timeIntervalSince1970: 0)
        var readings = 0
        let result = HookShim.handle(
            stdinData: stopInput(),
            voiceSessionEnabled: { true },
            now: {
                // The shim reads the clock twice per poll, once on each side of the send.
                // Advance it only on the closing reading of every third poll, so two
                // instant renewals are always followed by an honest one.
                readings += 1
                let poll = (readings - 1) / 2
                if readings.isMultiple(of: 2), poll % 3 == 2 {
                    t = t.addingTimeInterval(VoiceSessionBudget.brokerPoll)
                }
                return t
            }
        ) { message, _ in
            guard message["type"]?.stringValue == WireType.instructionWait else {
                return Data(#"{"ok":true}"#.utf8)
            }
            waits += 1
            return waits < 30
                ? BrokerResponse.instructionWaitRenew.encoded()
                : BrokerResponse.instructionWait(instruction: "still here").encoded()
        }
        XCTAssertEqual(waits, 30, "an occasional fast round trip is not a spin")
        XCTAssertEqual(try blockReason(result.stdout), "still here")
    }

    /// The broker was unreachable for the stop question, so it is unreachable for the wait
    /// too. Trying anyway would spend another socket timeout discovering that.
    func testAnUnreachableStopQuestionSkipsTheWaitEntirely() throws {
        let path = try transcript("Should I deploy?")
        var sentTypes: [String] = []
        let result = HookShim.handle(
            stdinData: stdin(#"{"hook_event_name":"Stop","session_id":"s1","permission_mode":"default","transcript_path":"\#(path)"}"#),
            voiceSessionEnabled: { true }
        ) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            throw StubError.unreachable
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(sentTypes, [WireType.stopQuestion])
    }
}
