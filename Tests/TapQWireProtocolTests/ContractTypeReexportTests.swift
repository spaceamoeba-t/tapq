import XCTest
import TapQWireProtocol

/// This file deliberately imports `TapQWireProtocol` alone. `JSONValue` and
/// `ApprovalSource` are declared in `TapQContracts` and re-exported by the wire module,
/// and consumers such as the hook shims name them with only the wire module in scope.
final class ContractTypeReexportTests: XCTestCase {
    func testWireModuleAloneVendsApprovalVocabularyWithUnchangedEncoding() throws {
        // Both types are named explicitly: without the re-export these annotations do
        // not resolve, which is the point of the test. Inferring them from
        // `ApprovalRequestMessage`'s own signature would prove nothing.
        let toolInput: [String: JSONValue] = ["command": .string("swift test")]
        let approvalSource: ApprovalSource = .preToolUse
        let message = ApprovalRequestMessage(
            token: "t",
            sessionID: "s",
            cwd: "/tmp",
            toolName: "Bash",
            toolInput: toolInput,
            permissionMode: "default",
            requestID: "r",
            approvalSource: approvalSource,
            protocolVersion: 3
        )

        let encoded = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""tool_input":{"command":"swift test"}"#))
        XCTAssertTrue(encoded.contains(#""approval_source":"pre_tool_use""#))
        XCTAssertTrue(encoded.contains(#""protocol_version":3"#))
    }
}
