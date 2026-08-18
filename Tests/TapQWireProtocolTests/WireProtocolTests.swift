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
        XCTAssertFalse(WireProtocol.isCompatible(nil), "v1-de-facto peers must fail a v5 check")
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
        // 3: rejected — v5 moved the acceptance floor up to v4
        XCTAssertFalse(WireProtocol.isCompatible(3))
        // 4: accepted (backward compat — v5 only adds instruction.submit)
        XCTAssertTrue(WireProtocol.isCompatible(4))
        // 5: accepted (current)
        XCTAssertTrue(WireProtocol.isCompatible(5))
    }

    func testInstalledV4ShimIsStillAcceptedByTheV5Wire() {
        XCTAssertEqual(WireProtocol.previousAcceptedVersion, 4)
        XCTAssertTrue(
            WireProtocol.isCompatible(WireProtocol.previousAcceptedVersion),
            "an installed v4 shim must keep working against a v5 runtime"
        )
        // …and a v5 shim keeps speaking v4 to a broker that has not been upgraded yet.
        XCTAssertEqual(WireProtocol.outboundVersion(for: 4, approvalSource: nil), 4)
    }

    func testShimNegotiatesV2OnlyForLegacySafeMessages() {
        // v5 shim → v5 broker: speak v5
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 5, approvalSource: .permissionRequest),
            5
        )
        // v5 shim → v4 broker: speak v4 (request shapes identical)
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 4, approvalSource: .permissionRequest),
            4
        )
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 4, approvalSource: .preToolUse),
            4
        )
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 4, approvalSource: nil),
            4
        )
        // v3 dropped out of the negotiation window when v5 landed.
        XCTAssertNil(WireProtocol.outboundVersion(for: 3, approvalSource: nil))
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
        XCTAssertNil(WireProtocol.outboundVersion(for: 6, approvalSource: nil))
    }

    func testInstructionSubmitOnlyNegotiatesWithACurrentBroker() {
        // Only a v5 peer may be handed an instruction — older brokers reject the type.
        XCTAssertEqual(
            WireProtocol.outboundVersion(
                for: 5, approvalSource: nil, messageType: WireType.instructionSubmit
            ),
            5
        )
        for peer in [4, 3, 2, 1] {
            XCTAssertNil(
                WireProtocol.outboundVersion(
                    for: peer, approvalSource: nil, messageType: WireType.instructionSubmit
                ),
                "a v\(peer) broker cannot be sent instruction.submit"
            )
        }
        XCTAssertNil(
            WireProtocol.outboundVersion(
                for: nil, approvalSource: nil, messageType: WireType.instructionSubmit
            )
        )
    }

    func testMessageTypeGatingLeavesPreV5TypesNegotiatingAsBefore() {
        // Passing an older type must reproduce the type-less negotiation exactly.
        for type in [WireType.approval, WireType.notification,
                     WireType.selection, WireType.stopQuestion] {
            XCTAssertEqual(WireProtocol.minimumVersion(for: type), 1)
            for peer: Int? in [nil, 1, 2, 3, 4, 5, 6] {
                XCTAssertEqual(
                    WireProtocol.outboundVersion(
                        for: peer, approvalSource: .preToolUse, messageType: type
                    ),
                    WireProtocol.outboundVersion(for: peer, approvalSource: .preToolUse),
                    "\(type) must negotiate identically with and without the type gate"
                )
            }
        }
        XCTAssertEqual(WireProtocol.minimumVersion(for: WireType.instructionSubmit), 5)
    }

    func testNilPeerIncompatibleOnceVersionBumps() {
        XCTAssertFalse(WireProtocol.isCompatible(nil, current: 2),
                       "an unstamped peer speaks v1 and must not pass a future version check")
        XCTAssertTrue(WireProtocol.isCompatible(1, current: 1))
        XCTAssertFalse(WireProtocol.isCompatible(1, current: 2))
    }

    func testVersionIsFiveAndRejectsPreApprovalSourcePeers() {
        XCTAssertEqual(WireProtocol.version, 5)
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

    func testDecodesInstructionSubmit() throws {
        let json = #"{"type":"instruction.submit","token":"abc","session_id":"s1","request_id":"r1","text":"go ahead, and run the tests again after","protocol_version":5}"#
        let request = try BrokerRequest(from: Data(json.utf8))
        guard case .instruction(let message) = request else {
            return XCTFail("expected instruction")
        }
        XCTAssertEqual(message.token, "abc")
        XCTAssertEqual(message.sessionID, "s1")
        XCTAssertEqual(message.requestID, "r1")
        XCTAssertEqual(message.text, "go ahead, and run the tests again after")
        XCTAssertEqual(message.protocolVersion, 5)
    }

    func testInstructionSubmitEncodesSnakeCaseWireKeys() throws {
        let message = InstructionSubmitMessage(
            token: "t",
            sessionID: "s",
            text: "run the tests again",
            requestID: "r",
            protocolVersion: WireProtocol.version
        )
        let encoded = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(encoded["session_id"]?.stringValue, "s")
        XCTAssertEqual(encoded["request_id"]?.stringValue, "r")
        XCTAssertEqual(encoded["protocol_version"]?.intValue, 5)
        XCTAssertNil(encoded["sessionID"])
        XCTAssertNil(encoded["requestID"])
        // The instruction channel carries text and nothing policy-significant.
        for forbidden in ["tool_name", "tool_input", "cwd", "permission_mode",
                          "approval_source"] {
            XCTAssertNil(encoded[forbidden], "\(forbidden) must not exist on an instruction")
        }
    }

    func testInstructionSubmitRoundTripsThroughTheDiscriminator() throws {
        let message = InstructionSubmitMessage(
            token: "t", sessionID: "s", text: "hold off on the deploy", requestID: "r",
            protocolVersion: WireProtocol.version
        )
        var encoded = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(message)
        )
        encoded["type"] = .string(WireType.instructionSubmit)
        let request = try BrokerRequest(from: try JSONEncoder().encode(encoded))
        guard case .instruction(let decoded) = request else {
            return XCTFail("expected instruction")
        }
        XCTAssertEqual(decoded, message)
    }

    func testInstructionSubmitWithoutProtocolVersionDecodesAsNil() throws {
        let json = #"{"type":"instruction.submit","token":"t","session_id":"s","request_id":"r","text":"x"}"#
        let request = try BrokerRequest(from: Data(json.utf8))
        guard case .instruction(let message) = request else {
            return XCTFail("expected instruction")
        }
        XCTAssertNil(message.protocolVersion)
    }

    func testStopQuestionResponsesRoundTrip() throws {
        for response: BrokerResponse in [.stopQuestion(reply: nil), .stopQuestion(reply: "x")] {
            let decoded = try JSONDecoder().decode(BrokerResponse.self, from: response.encoded())
            XCTAssertEqual(decoded, response)
        }
    }
}
