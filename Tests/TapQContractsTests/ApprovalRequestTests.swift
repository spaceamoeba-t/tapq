import XCTest
@testable import TapQContracts

final class ApprovalRequestTests: XCTestCase {
    func testApprovalContextDefaultsToNil() {
        let request = ApprovalRequest(id: "1", sessionID: "s", toolName: "Bash",
                                      summary: "run the test suite", detail: "swift test")

        XCTAssertNil(request.toolInput)
        XCTAssertNil(request.cwd)
        XCTAssertNil(request.permissionMode)
        XCTAssertNil(request.approvalSource)
        XCTAssertEqual(request.kind, .toolApproval)
        XCTAssertEqual(request.agent, .unknown)
    }

    func testApprovalContextIsCarriedWhenProvided() {
        let request = ApprovalRequest(
            id: "1", sessionID: "s", agent: .claudeCode,
            toolName: "Bash", summary: "run a command", detail: "swift test",
            toolInput: ["command": .string("swift test"), "timeout": .number(120)],
            cwd: "/Users/dev/project",
            permissionMode: "default",
            approvalSource: .permissionRequest
        )

        XCTAssertEqual(request.toolInput?["command"]?.stringValue, "swift test")
        XCTAssertEqual(request.toolInput?["timeout"]?.intValue, 120)
        XCTAssertEqual(request.cwd, "/Users/dev/project")
        XCTAssertEqual(request.permissionMode, "default")
        XCTAssertEqual(request.approvalSource, .permissionRequest)
        XCTAssertEqual(request.kind, .toolApproval, "context must not disturb the defaulted kind")
    }

    func testDescriptionsRedactRequestContext() {
        let request = ApprovalRequest(
            id: "r1", sessionID: "s", agent: .claudeCode,
            toolName: "Bash",
            summary: "run a deploy script",
            detail: "deploy.sh --production",
            toolInput: ["command": .string("cat ~/.aws/credentials")],
            cwd: "/Users/dev/private-notes",
            permissionMode: "default",
            approvalSource: .preToolUse
        )

        for rendering in [String(describing: request), String(reflecting: request)] {
            XCTAssertTrue(rendering.contains("Bash"))
            XCTAssertTrue(rendering.contains("r1"))
            XCTAssertTrue(rendering.contains("claude-code"))
            for secret in ["cat ~/.aws/credentials", "private-notes",
                           "run a deploy script", "deploy.sh"] {
                XCTAssertFalse(rendering.contains(secret),
                               "interpolating a request leaked \(secret)")
            }
        }
    }

    func testEqualityAccountsForApprovalContext() {
        func request(command: String) -> ApprovalRequest {
            ApprovalRequest(id: "1", sessionID: "s", toolName: "Bash",
                            summary: "run a command", detail: "a command",
                            toolInput: ["command": .string(command)],
                            cwd: "/tmp", permissionMode: "default",
                            approvalSource: .preToolUse)
        }

        XCTAssertEqual(request(command: "swift test"), request(command: "swift test"))
        XCTAssertNotEqual(request(command: "swift test"), request(command: "rm -rf /"))
    }
}

/// `JSONValue` and `ApprovalSource` moved here from `TapQWireProtocol` so the in-process
/// `ApprovalRequest` can carry them. Their encodings are still wire-visible, so pin them.
final class ApprovalContextCodingTests: XCTestCase {
    func testJSONValueRoundTripsEveryCase() throws {
        let value = JSONValue.object([
            "command": .string("swift test"),
            "timeout": .number(120),
            "sandbox": .bool(false),
            "cwd": .null,
            "args": .array([.string("--filter"), .number(2)]),
        ])

        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testApprovalSourceKeepsWireStrings() throws {
        XCTAssertEqual(ApprovalSource.preToolUse.rawValue, "pre_tool_use")
        XCTAssertEqual(ApprovalSource.permissionRequest.rawValue, "permission_request")

        for source: ApprovalSource in [.preToolUse, .permissionRequest] {
            let data = try JSONEncoder().encode(source)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(source.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(ApprovalSource.self, from: data), source)
        }
    }

    func testUnknownApprovalSourceFailsToDecode() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(ApprovalSource.self, from: Data(#""future_event""#.utf8))
        )
    }
}
