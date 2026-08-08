import XCTest
@testable import TapQWireProtocol
import TapQContracts

final class WireProtocolTests: XCTestCase {
    func testDecodesLegacyApprovalRequestWithoutSource() throws {
        let json = """
        {"type":"approval.request","token":"abc","session_id":"s1","cwd":"/tmp",
         "tool_name":"Bash","tool_input":{"command":"npm test"},
         "permission_mode":"default","request_id":"r1","protocol_version":2}
        """
        let request = try BrokerRequest(from: Data(json.utf8))
        guard case .approval(let message) = request else { return XCTFail("expected approval") }
        XCTAssertEqual(message.token, "abc")
        XCTAssertEqual(message.sessionID, "s1")
        XCTAssertEqual(message.toolName, "Bash")
        XCTAssertEqual(message.toolInput["command"]?.stringValue, "npm test")
        XCTAssertEqual(message.requestID, "r1")
        XCTAssertEqual(message.protocolVersion, 2)
        // Decoding supports the v2 bridge. BrokerServer separately requires this field
        // when accepting a v3 approval request.
        XCTAssertNil(message.approvalSource)
    }

    func testDecodesApprovalSource() throws {
        for (rawValue, expected): (String, ApprovalSource) in [
            ("pre_tool_use", .preToolUse),
            ("permission_request", .permissionRequest),
        ] {
            let json = #"{"type":"approval.request","token":"t","session_id":"s","tool_name":"Bash","tool_input":{},"approval_source":"\#(rawValue)","request_id":"r","protocol_version":3}"#
            let request = try BrokerRequest(from: Data(json.utf8))
            guard case .approval(let message) = request else {
                return XCTFail("expected approval")
            }
            XCTAssertEqual(message.approvalSource, expected)
        }
    }

    func testApprovalSourceEncodesWithSnakeCaseWireKey() throws {
        let message = ApprovalRequestMessage(
            token: "t",
            sessionID: "s",
            cwd: nil,
            toolName: "Bash",
            toolInput: [:],
            permissionMode: "default",
            requestID: "r",
            approvalSource: .permissionRequest,
            protocolVersion: 3
        )
        let encoded = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(encoded["approval_source"]?.stringValue, "permission_request")
        XCTAssertNil(encoded["approvalSource"])
    }

    func testDecodesNotification() throws {
        let json = """
        {"type":"notification.event","token":"abc","session_id":"s1","event":"stop"}
        """
        let request = try BrokerRequest(from: Data(json.utf8))
        guard case .notification(let message) = request else { return XCTFail("expected notification") }
        XCTAssertEqual(message.event, .stop)
        XCTAssertNil(message.summary)
    }

    func testUnknownTypeThrows() {
        let json = #"{"type":"mystery","token":"abc"}"#
        XCTAssertThrowsError(try BrokerRequest(from: Data(json.utf8)))
    }

    func testEncodesDecisionResponses() throws {
        let allow = String(decoding: BrokerResponse.decision(.allow, reason: nil).encoded(), as: UTF8.self)
        XCTAssertEqual(allow, #"{"decision":"allow"}"#)

        let deny = String(decoding: BrokerResponse.decision(.deny, reason: "Denied via TapQ").encoded(), as: UTF8.self)
        XCTAssertTrue(deny.contains(#""decision":"deny""#))
        XCTAssertTrue(deny.contains(#""reason":"Denied via TapQ""#))

        let ok = String(decoding: BrokerResponse.ok.encoded(), as: UTF8.self)
        XCTAssertEqual(ok, #"{"ok":true}"#)
    }

    func testResponseRoundTrips() throws {
        for response: BrokerResponse in [
            .decision(.ask, reason: nil),
            .ok,
            .error("nope"),
            .selection(indices: [0], labels: ["A"]),
            .selection(indices: [], labels: [], freeText: "typed answer"),
        ] {
            let data = response.encoded()
            let decoded = try JSONDecoder().decode(BrokerResponse.self, from: data)
            XCTAssertEqual(decoded, response)
        }
    }

    func testApprovalMessageRoundTripsProtocolVersion() throws {
        let json = #"{"type":"approval.request","token":"t","session_id":"s","tool_name":"Bash","tool_input":{},"request_id":"r","protocol_version":1}"#
        let request = try BrokerRequest(from: Data(json.utf8))
        guard case .approval(let msg) = request else { return XCTFail("expected approval") }
        XCTAssertEqual(msg.protocolVersion, 1)
    }

    func testMessageWithoutProtocolVersionDecodesAsNil() throws {
        let json = #"{"type":"approval.request","token":"t","session_id":"s","tool_name":"Bash","tool_input":{},"request_id":"r"}"#
        let request = try BrokerRequest(from: Data(json.utf8))
        guard case .approval(let msg) = request else { return XCTFail("expected approval") }
        XCTAssertNil(msg.protocolVersion)
    }

    func testCompatibilityRule() {
        XCTAssertFalse(WireProtocol.isCompatible(nil), "v1-de-facto peers must fail a v4 check")
        XCTAssertTrue(WireProtocol.isCompatible(WireProtocol.version))
        XCTAssertFalse(WireProtocol.isCompatible(WireProtocol.version + 1))
    }

    func testVersionAcceptanceMatrix() {
        // nil (v1 de facto): rejected
        XCTAssertFalse(WireProtocol.isCompatible(nil))
        // 1: rejected
        XCTAssertFalse(WireProtocol.isCompatible(1))
        // 2: rejected (was already rejected in v3)
        XCTAssertFalse(WireProtocol.isCompatible(2))
        // 3: accepted (backward compat — request shapes identical to v4)
        XCTAssertTrue(WireProtocol.isCompatible(3))
        // 4: accepted (current)
        XCTAssertTrue(WireProtocol.isCompatible(4))
    }

    func testShimNegotiatesV2OnlyForLegacySafeMessages() {
        // v4 shim → v4 broker: speak v4
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 4, approvalSource: .permissionRequest),
            4
        )
        // v4 shim → v3 broker: speak v3 (request shapes identical)
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 3, approvalSource: .permissionRequest),
            3
        )
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 3, approvalSource: .preToolUse),
            3
        )
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 3, approvalSource: nil),
            3
        )
        // v2 bridge rules unchanged
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 2, approvalSource: .preToolUse),
            2
        )
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 2, approvalSource: nil),
            2
        )
        XCTAssertNil(
            WireProtocol.outboundVersion(for: 2, approvalSource: .permissionRequest)
        )
        XCTAssertNil(WireProtocol.outboundVersion(for: nil, approvalSource: nil))
        // Unknown future version: nil
        XCTAssertNil(WireProtocol.outboundVersion(for: 5, approvalSource: nil))
    }

    func testNilPeerIncompatibleOnceVersionBumps() {
        XCTAssertFalse(WireProtocol.isCompatible(nil, current: 2),
                       "an unstamped peer speaks v1 and must not pass a future version check")
        XCTAssertTrue(WireProtocol.isCompatible(1, current: 1))
        XCTAssertFalse(WireProtocol.isCompatible(1, current: 2))
    }

    func testVersionIsFourAndRejectsPreApprovalSourcePeers() {
        XCTAssertEqual(WireProtocol.version, 4)
        XCTAssertFalse(WireProtocol.isCompatible(2),
                       "v2 peers do not understand policy-significant approval_source")
    }

    func testUnknownApprovalSourceIsRejected() {
        let json = #"{"type":"approval.request","token":"t","session_id":"s","tool_name":"Bash","tool_input":{},"approval_source":"future_event","request_id":"r","protocol_version":3}"#
        XCTAssertThrowsError(try BrokerRequest(from: Data(json.utf8)))
    }

    func testDecodesStopQuestion() throws {
        let json = #"{"type":"stop.question","token":"abc","session_id":"s1","request_id":"r1","text":"Which? 1) A 2) B","protocol_version":3}"#
        let request = try BrokerRequest(from: Data(json.utf8))
        guard case .stopQuestion(let message) = request else { return XCTFail("expected stopQuestion") }
        XCTAssertEqual(message.token, "abc")
        XCTAssertEqual(message.sessionID, "s1")
        XCTAssertEqual(message.requestID, "r1")
        XCTAssertEqual(message.text, "Which? 1) A 2) B")
        XCTAssertEqual(message.protocolVersion, 3)
    }

    func testEncodesStopQuestionResponses() throws {
        let pass = String(decoding: BrokerResponse.stopQuestion(reply: nil).encoded(), as: UTF8.self)
        XCTAssertEqual(pass, #"{"action":"pass"}"#)

        let answer = String(decoding: BrokerResponse.stopQuestion(reply: "pick A").encoded(), as: UTF8.self)
        XCTAssertTrue(answer.contains(#""action":"answer""#))
        XCTAssertTrue(answer.contains(#""reply":"pick A""#))
    }

    func testStopQuestionResponsesRoundTrip() throws {
        for response: BrokerResponse in [.stopQuestion(reply: nil), .stopQuestion(reply: "x")] {
            let decoded = try JSONDecoder().decode(BrokerResponse.self, from: response.encoded())
            XCTAssertEqual(decoded, response)
        }
    }
}
