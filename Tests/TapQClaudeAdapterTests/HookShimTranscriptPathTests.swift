import XCTest
@testable import TapQClaudeAdapter
import TapQContracts
import TapQWireProtocol

/// The shim forwarding `transcript_path` on the messages it already sends.
///
/// Every Claude Code hook invocation carries the path and the shim already opens the file
/// for the final assistant message. What is added is only the forwarding: a location, on
/// messages that already existed, under the version they already used.
final class HookShimTranscriptPathTests: XCTestCase {
    /// Captures what the shim would have put on the socket.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [[String: JSONValue]] = []

        func record(_ message: [String: JSONValue]) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        var all: [[String: JSONValue]] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }

        func first(ofType type: String) -> [String: JSONValue]? {
            all.first { $0["type"]?.stringValue == type }
        }
    }

    private func run(_ json: String, reply: String = #"{"ok":true}"#) -> Sent {
        let sent = Sent()
        _ = HookShim.handle(stdinData: Data(json.utf8)) { message, _ in
            sent.record(message)
            return Data(reply.utf8)
        }
        return sent
    }

    // MARK: - Forwarded

    func testAnApprovalCarriesTheHooksTranscriptPath() throws {
        let sent = run(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","#
            + #""tool_input":{"command":"swift test"},"request_id":"r1","#
            + #""transcript_path":"/tmp/claude/session.jsonl"}"#)

        let message = try XCTUnwrap(sent.first(ofType: WireType.approval))
        XCTAssertEqual(message["transcript_path"]?.stringValue, "/tmp/claude/session.jsonl")
    }

    func testANotificationCarriesTheHooksTranscriptPath() throws {
        let sent = run(#"{"hook_event_name":"Notification","session_id":"s1","#
            + #""message":"Claude needs your permission","#
            + #""transcript_path":"/tmp/claude/session.jsonl"}"#)

        let message = try XCTUnwrap(sent.first(ofType: WireType.notification))
        XCTAssertEqual(message["transcript_path"]?.stringValue, "/tmp/claude/session.jsonl")
    }

    /// The Stop notification is the one every session produces whether or not it ever asks
    /// for anything, so it is how a session that only finishes turns becomes one TapQ knows
    /// the transcript of.
    func testTheStopNotificationCarriesTheHooksTranscriptPath() throws {
        let sent = run(#"{"hook_event_name":"Stop","session_id":"s1","#
            + #""transcript_path":"/tmp/claude/session.jsonl"}"#)

        let message = try XCTUnwrap(sent.first(ofType: WireType.notification))
        XCTAssertEqual(message["event"]?.stringValue, "stop")
        XCTAssertEqual(message["transcript_path"]?.stringValue, "/tmp/claude/session.jsonl")
    }

    /// The shim does not check the path, stat it, or read it for this: a location is all it
    /// forwards, and whether the file is readable is the runtime store's question.
    func testAPathIsForwardedWithoutBeingRead() throws {
        let sent = run(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","#
            + #""tool_input":{},"request_id":"r1","#
            + #""transcript_path":"/definitely/not/here.jsonl"}"#)

        let message = try XCTUnwrap(sent.first(ofType: WireType.approval))
        XCTAssertEqual(message["transcript_path"]?.stringValue, "/definitely/not/here.jsonl")
    }

    // MARK: - Absent

    /// A hook payload with no path — or a blank one — sends null, which a broker reads as no
    /// transcript and an older broker ignores entirely.
    func testAMissingOrBlankPathIsSentAsNull() throws {
        for json in [
            #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{},"request_id":"r1"}"#,
            #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{},"request_id":"r1","transcript_path":"   "}"#,
        ] {
            let sent = run(json)
            let message = try XCTUnwrap(sent.first(ofType: WireType.approval))
            XCTAssertEqual(message["transcript_path"], .null)
        }
    }

    // MARK: - Nothing else moved

    /// The version the shim stamps is untouched, which is the whole additive claim.
    func testTheForwardedMessagesStillCarryTheCurrentVersion() throws {
        let sent = run(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","#
            + #""tool_input":{},"request_id":"r1","transcript_path":"/tmp/s.jsonl"}"#)

        let message = try XCTUnwrap(sent.first(ofType: WireType.approval))
        XCTAssertEqual(message["protocol_version"], .number(Double(WireProtocol.version)))
    }

    /// And the whole message still decodes into the shape the broker reads, with the path on
    /// it — the shim's output and the broker's input agreeing is the actual contract.
    func testTheForwardedApprovalDecodesAsTheBrokerWouldReadIt() throws {
        let sent = run(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","#
            + #""tool_input":{"command":"swift test"},"request_id":"r1","#
            + #""transcript_path":"/tmp/claude/session.jsonl"}"#)

        // The token is added by the executable's socket client rather than by the shim, so
        // it is supplied here to make the bytes the ones the broker actually reads.
        var message = try XCTUnwrap(sent.first(ofType: WireType.approval))
        message["token"] = .string("tok")
        let data = try JSONEncoder().encode(message)
        guard case .approval(let decoded) = try BrokerRequest(from: data) else {
            return XCTFail("the shim's own message did not decode as an approval")
        }
        XCTAssertEqual(decoded.transcriptPath, "/tmp/claude/session.jsonl")
        XCTAssertEqual(decoded.sessionID, "s1")
    }
}
