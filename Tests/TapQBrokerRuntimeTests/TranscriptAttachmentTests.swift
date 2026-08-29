import XCTest
@testable import TapQBrokerRuntime
import TapQContracts
import TapQWireProtocol

/// The broker's transcript seam: a path forwarded on a message it already handles, handed
/// to a host that has somewhere to put it — and, on the Apple path, to nobody.
@MainActor
final class TranscriptAttachmentTests: XCTestCase {
    /// The socket is not what is under test here; `handle` is the whole dispatcher.
    private final class StubTransport: BrokerTransport {
        func start(handler: @escaping @Sendable (Data) async -> Data) throws {}
        func stop() {}
    }

    private final class Attachments {
        var received: [BrokerTranscriptAttachment] = []
    }

    private func makeServer(
        attachments: Attachments?,
        onApproval: @escaping @MainActor (ApprovalRequest) async -> Decision = { _ in .allow },
        onNotification: @escaping @MainActor (AgentNotification) -> Void = { _ in },
        onStopQuestion: @escaping @MainActor (StopQuestion) async -> String? = { _ in nil }
    ) -> BrokerServer {
        BrokerServer(
            transport: StubTransport(),
            token: "tok",
            onApproval: onApproval,
            onNotification: onNotification,
            onStopQuestion: onStopQuestion,
            onTranscriptPath: attachments.map { box in
                { attachment in box.received.append(attachment) }
            }
        )
    }

    private func approval(transcriptPath: String? = nil) -> Data {
        var fields = [
            #""type":"approval.request""#, #""token":"tok""#, #""session_id":"s1""#,
            #""tool_name":"Bash""#, #""tool_input":{}"#, #""request_id":"r1""#,
            #""approval_source":"pre_tool_use""#, #""protocol_version":6"#,
            #""agent":{"id":"claude-code","display_name":"Claude Code"}"#,
        ]
        if let transcriptPath { fields.append(#""transcript_path":"\#(transcriptPath)""#) }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    private func notification(transcriptPath: String?) -> Data {
        var fields = [
            #""type":"notification.event""#, #""token":"tok""#, #""session_id":"s2""#,
            #""event":"stop""#, #""protocol_version":6"#,
            #""agent":{"id":"claude-code","display_name":"Claude Code"}"#,
        ]
        if let transcriptPath { fields.append(#""transcript_path":"\#(transcriptPath)""#) }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    private func stopQuestion(transcriptPath: String?) -> Data {
        var fields = [
            #""type":"stop.question""#, #""token":"tok""#, #""session_id":"s3""#,
            #""request_id":"r2""#, #""text":"Shall I continue?""#, #""protocol_version":6"#,
            #""agent":{"id":"claude-code","display_name":"Claude Code"}"#,
        ]
        if let transcriptPath { fields.append(#""transcript_path":"\#(transcriptPath)""#) }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    // MARK: - Forwarded to a host that wants it

    func testEveryCarryingMessageReachesTheHost() async {
        let attachments = Attachments()
        let server = makeServer(attachments: attachments)

        _ = await server.handle(approval(transcriptPath: "/tmp/a.jsonl"))
        _ = await server.handle(notification(transcriptPath: "/tmp/b.jsonl"))
        _ = await server.handle(stopQuestion(transcriptPath: "/tmp/c.jsonl"))

        XCTAssertEqual(attachments.received.map(\.sessionID), ["s1", "s2", "s3"])
        XCTAssertEqual(attachments.received.map(\.path),
                       ["/tmp/a.jsonl", "/tmp/b.jsonl", "/tmp/c.jsonl"])
        XCTAssertEqual(attachments.received.first?.agent, .claudeCode)
    }

    /// The path is a fact about the session, not a decision: the approval still resolves
    /// exactly as the host said, and the reply on the wire is unchanged.
    func testAnAttachmentChangesNoDecision() async {
        let attachments = Attachments()
        let server = makeServer(attachments: attachments, onApproval: { _ in .deny })

        let withPath = await server.handle(approval(transcriptPath: "/tmp/a.jsonl"))
        let without = await server.handle(approval())

        XCTAssertEqual(withPath, without)
        let decoded = try? JSONDecoder().decode(BrokerResponse.self, from: withPath)
        XCTAssertEqual(decoded, .decision(.deny, reason: "Denied via TapQ"))
    }

    // MARK: - Nothing to attach, or nobody to attach it to

    /// The Apple path. The field still arrives and still decodes; there is simply no
    /// callback, so nothing is ever read from disk. Structurally absent, not disabled.
    func testWithoutAHostCallbackAPathGoesNowhere() async {
        let server = makeServer(attachments: nil)

        let response = await server.handle(approval(transcriptPath: "/tmp/a.jsonl"))

        let decoded = try? JSONDecoder().decode(BrokerResponse.self, from: response)
        XCTAssertEqual(decoded, .decision(.allow, reason: nil))
    }

    /// `acceptEdits` and `bypassPermissions` answer every tool call at the broker without
    /// asking the wearer. The path still has to land, or a run in one of those modes would
    /// not know where its transcript is until its first turn boundary.
    func testAnAutoAnsweredApprovalStillAttachesItsTranscript() async {
        let attachments = Attachments()
        let server = makeServer(attachments: attachments)
        let json = #"{"type":"approval.request","token":"tok","session_id":"s1","#
            + #""tool_name":"Edit","tool_input":{},"request_id":"r1","#
            + #""approval_source":"pre_tool_use","permission_mode":"acceptEdits","#
            + #""transcript_path":"/tmp/a.jsonl","protocol_version":6}"#

        let response = await server.handle(Data(json.utf8))

        let decoded = try? JSONDecoder().decode(BrokerResponse.self, from: response)
        XCTAssertEqual(decoded, .decision(.allow, reason: nil), "the auto-pass is unchanged")
        XCTAssertEqual(attachments.received.map(\.path), ["/tmp/a.jsonl"])
    }

    /// A shim too old to send one, and a shim that sent a blank, are the same thing: no
    /// attachment.
    func testAMissingOrBlankPathIsNotAnAttachment() async {
        let attachments = Attachments()
        let server = makeServer(attachments: attachments)

        _ = await server.handle(approval())
        _ = await server.handle(notification(transcriptPath: nil))
        _ = await server.handle(approval(transcriptPath: "   "))

        XCTAssertTrue(attachments.received.isEmpty)
    }
}
