import XCTest
import TapQContracts
@testable import TapQWireProtocol

/// `transcript_path`: one optional field on three messages that already existed, added
/// without moving the wire version.
///
/// The claim being tested is the `lease_id` claim, restated for this field: both directions
/// are inert to a peer that does not know it. A message carrying it decodes in a build that
/// does, a message without it decodes as nothing in the same build, and nothing about the
/// version negotiation moves — so an installed shim and a running runtime that disagree
/// about this field still talk.
final class TranscriptWireFieldTests: XCTestCase {
    // MARK: - Carried

    func testAnApprovalCarriesTheTranscriptPath() throws {
        let json = #"{"type":"approval.request","token":"t","session_id":"s1","tool_name":"Bash","#
            + #""tool_input":{},"approval_source":"pre_tool_use","request_id":"r1","#
            + #""transcript_path":"/tmp/session.jsonl","protocol_version":6}"#
        guard case .approval(let message) = try BrokerRequest(from: Data(json.utf8)) else {
            return XCTFail("expected an approval")
        }
        XCTAssertEqual(message.transcriptPath, "/tmp/session.jsonl")
    }

    func testANotificationCarriesTheTranscriptPath() throws {
        let json = #"{"type":"notification.event","token":"t","session_id":"s1","event":"stop","#
            + #""transcript_path":"/tmp/session.jsonl","protocol_version":6}"#
        guard case .notification(let message) = try BrokerRequest(from: Data(json.utf8)) else {
            return XCTFail("expected a notification")
        }
        XCTAssertEqual(message.transcriptPath, "/tmp/session.jsonl")
    }

    func testAStopQuestionCarriesTheTranscriptPath() throws {
        let json = #"{"type":"stop.question","token":"t","session_id":"s1","request_id":"r1","#
            + #""text":"Shall I continue?","transcript_path":"/tmp/session.jsonl","#
            + #""protocol_version":6}"#
        guard case .stopQuestion(let message) = try BrokerRequest(from: Data(json.utf8)) else {
            return XCTFail("expected a stop question")
        }
        XCTAssertEqual(message.transcriptPath, "/tmp/session.jsonl")
    }

    // MARK: - Absent

    /// The other direction, and the reason no version gate was needed: a shim that predates
    /// the field sends none, and a runtime that knows about it reads that as "no transcript"
    /// — which is the state every run was in before this existed.
    func testAMessageWithoutTheFieldDecodesAsNoTranscript() throws {
        let approval = #"{"type":"approval.request","token":"t","session_id":"s1","#
            + #""tool_name":"Bash","tool_input":{},"approval_source":"pre_tool_use","#
            + #""request_id":"r1","protocol_version":6}"#
        guard case .approval(let message) = try BrokerRequest(from: Data(approval.utf8)) else {
            return XCTFail("expected an approval")
        }
        XCTAssertNil(message.transcriptPath)

        let notification = #"{"type":"notification.event","token":"t","session_id":"s1","#
            + #""event":"stop","protocol_version":6}"#
        guard case .notification(let note) = try BrokerRequest(from: Data(notification.utf8))
        else {
            return XCTFail("expected a notification")
        }
        XCTAssertNil(note.transcriptPath)
    }

    /// An explicit `null` is the same as an absent key. The shim encodes null rather than
    /// omitting the key so the message shape stays fixed.
    func testAnExplicitNullReadsAsNoTranscript() throws {
        let json = #"{"type":"notification.event","token":"t","session_id":"s1","event":"stop","#
            + #""transcript_path":null,"protocol_version":6}"#
        guard case .notification(let message) = try BrokerRequest(from: Data(json.utf8)) else {
            return XCTFail("expected a notification")
        }
        XCTAssertNil(message.transcriptPath)
    }

    /// An older broker's `Codable` ignores a key it does not model. Stated here by decoding
    /// the same bytes into a shape that has no such field — the same proof shape the
    /// lease-id tests use for the other direction.
    func testAPeerThatDoesNotModelTheFieldIgnoresIt() throws {
        struct OlderNotification: Decodable {
            let sessionID: String
            let event: String

            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case event
            }
        }
        let json = #"{"type":"notification.event","token":"t","session_id":"s1","event":"stop","#
            + #""transcript_path":"/tmp/session.jsonl","protocol_version":6}"#
        let older = try JSONDecoder().decode(OlderNotification.self, from: Data(json.utf8))
        XCTAssertEqual(older.sessionID, "s1")
        XCTAssertEqual(older.event, "stop")
    }

    // MARK: - The version did not move

    /// The whole point of the additive shape: nothing about negotiation changed, so a v5 or
    /// v4 peer keeps talking exactly as it did.
    func testTheWireVersionAndNegotiationAreUnchanged() {
        XCTAssertEqual(WireProtocol.version, 6)
        XCTAssertEqual(WireProtocol.minimumVersion(for: WireType.approval), 1)
        XCTAssertEqual(WireProtocol.minimumVersion(for: WireType.notification), 1)
        XCTAssertEqual(WireProtocol.minimumVersion(for: WireType.stopQuestion), 1)
        XCTAssertTrue(WireProtocol.isCompatible(5))
        XCTAssertTrue(WireProtocol.isCompatible(4))
    }

    /// A path sent to an older broker under that broker's own version is still just a field
    /// it ignores, so the negotiated outbound version is unaffected by carrying one.
    func testCarryingAPathDoesNotChangeTheOutboundVersion() {
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 5, approvalSource: .preToolUse,
                                         messageType: WireType.approval),
            5
        )
        XCTAssertEqual(
            WireProtocol.outboundVersion(for: 6, approvalSource: nil,
                                         messageType: WireType.notification),
            6
        )
    }

    // MARK: - Round trip

    func testAPathSurvivesAnEncodeDecodeRoundTrip() throws {
        let message = StopQuestionMessage(
            token: "t", sessionID: "s1", requestID: "r1", text: "Shall I continue?",
            agent: .claudeCode, transcriptPath: "/tmp/session.jsonl", protocolVersion: 6
        )
        let data = try JSONEncoder().encode(message)
        let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(object["transcript_path"]?.stringValue, "/tmp/session.jsonl")

        let decoded = try JSONDecoder().decode(StopQuestionMessage.self, from: data)
        XCTAssertEqual(decoded, message)
    }
}
