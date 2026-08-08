import XCTest
@testable import TapQOpenCodeAdapter
import TapQContracts
import TapQWireProtocol

/// Realistic relay payloads. Every field is what TapQ's installed plugin writes for the
/// corresponding OpenCode bus event, so these double as the plugin↔executable contract.
///
/// The values mirror a real `permission.asked` request: a `per_`-prefixed permission id, a
/// `ses_`-prefixed session id, the `permission` kind string, and the kind's own `metadata`
/// object. See
/// https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/v1/permission.ts
private enum RelayFixture {
    static let permissionAsked = """
    {
      "tapq_relay_version": 1,
      "hook_event_name": "permission.asked",
      "session_id": "ses_01K7Q0000000000000000001",
      "permission_id": "per_01K7Q0000000000000000002",
      "permission": "bash",
      "metadata": {"command": "rm -rf build", "description": "Remove the build directory"},
      "directory": "/tmp/tapq-opencode-workspace"
    }
    """

    static let sessionIdle = """
    {
      "tapq_relay_version": 1,
      "hook_event_name": "session.idle",
      "session_id": "ses_01K7Q0000000000000000001",
      "directory": "/tmp/tapq-opencode-workspace"
    }
    """

    static func permissionAsked(
        mutating mutate: (inout [String: JSONValue]) -> Void
    ) throws -> Data {
        var object = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(permissionAsked.utf8)
        )
        mutate(&object)
        return try JSONEncoder().encode(object)
    }
}

final class OpenCodeHookShimTests: XCTestCase {
    private var sent: [[String: JSONValue]] = []
    private var timeouts: [TimeInterval] = []

    private func handle(
        _ data: Data,
        reply: @escaping ([String: JSONValue]) -> Data
    ) -> OpenCodeHookShim.Result {
        var captured: [[String: JSONValue]] = []
        var capturedTimeouts: [TimeInterval] = []
        let result = OpenCodeHookShim.handle(stdinData: data) { message, timeout in
            captured.append(message)
            capturedTimeouts.append(timeout)
            return reply(message)
        }
        sent = captured
        timeouts = capturedTimeouts
        return result
    }

    private func decision(_ raw: String) -> ([String: JSONValue]) -> Data {
        { _ in Data(raw.utf8) }
    }

    private func decodedStdout(_ result: OpenCodeHookShim.Result) throws -> [String: JSONValue] {
        let stdout = try XCTUnwrap(result.stdout)
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(stdout.utf8))
    }

    private func assertNoBrokerTraffic(
        _ data: Data,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var reached = false
        let result = OpenCodeHookShim.handle(stdinData: data) { _, _ in
            reached = true
            return Data(#"{"decision":"allow"}"#.utf8)
        }
        XCTAssertEqual(result, OpenCodeHookShim.passThrough, message, file: file, line: line)
        XCTAssertFalse(reached, message, file: file, line: line)
    }

    // MARK: - permission.asked

    func testPermissionAskedSendsANormalizedApprovalAndEmitsAllow() throws {
        let result = handle(
            Data(RelayFixture.permissionAsked.utf8),
            reply: decision(#"{"decision":"allow"}"#)
        )

        let message = try XCTUnwrap(sent.only)
        XCTAssertEqual(message["type"]?.stringValue, WireType.approval)
        XCTAssertEqual(message["agent"]?["id"]?.stringValue, "opencode")
        XCTAssertEqual(message["agent"]?["display_name"]?.stringValue, "OpenCode")
        XCTAssertEqual(message["session_id"]?.stringValue, "ses_01K7Q0000000000000000001")
        XCTAssertEqual(message["request_id"]?.stringValue, "per_01K7Q0000000000000000002")
        XCTAssertEqual(message["tool_name"]?.stringValue, "bash")
        XCTAssertEqual(message["cwd"]?.stringValue, "/tmp/tapq-opencode-workspace")
        XCTAssertEqual(
            message["approval_source"]?.stringValue,
            ApprovalSource.permissionRequest.rawValue
        )
        XCTAssertEqual(message["tool_input"]?["command"]?.stringValue, "rm -rf build")
        XCTAssertEqual(message["summary"]?.stringValue, "run rm -rf build")
        XCTAssertEqual(message["detail"]?.stringValue, "Run the command: rm -rf build")
        XCTAssertEqual(message["permission_mode"], .null)
        XCTAssertEqual(
            message["protocol_version"],
            .number(Double(WireProtocol.version))
        )
        XCTAssertEqual(timeouts, [OpenCodeHookShim.approvalTimeout])

        let output = try decodedStdout(result)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(Set(output.keys), ["hookEventName", "decision"])
        XCTAssertEqual(output["hookEventName"]?.stringValue, "permission.asked")
        XCTAssertEqual(output["decision"]?["behavior"]?.stringValue, "allow")
        XCTAssertNil(output["decision"]?["message"]?.stringValue)
    }

    func testPermissionAskedEmitsDenyWithTheBrokerReason() throws {
        let result = handle(
            Data(RelayFixture.permissionAsked.utf8),
            reply: decision(#"{"decision":"deny","reason":"Not while the build is running"}"#)
        )

        let output = try decodedStdout(result)
        XCTAssertEqual(output["decision"]?["behavior"]?.stringValue, "deny")
        XCTAssertEqual(
            output["decision"]?["message"]?.stringValue,
            "Not while the build is running"
        )
    }

    func testPermissionAskedDenyFallsBackToTheDefaultReason() throws {
        let result = handle(
            Data(RelayFixture.permissionAsked.utf8),
            reply: decision(#"{"decision":"deny"}"#)
        )

        let output = try decodedStdout(result)
        XCTAssertEqual(output["decision"]?["message"]?.stringValue, "Denied via TapQ")
        XCTAssertEqual(OpenCodeHookShim.denyReason, "Denied via TapQ")
    }

    func testAnUnrecognizedPermissionKindStillReachesTheBrokerGenerically() throws {
        let payload = try RelayFixture.permissionAsked { object in
            object["permission"] = .string("external_directory")
            object["metadata"] = .object(["path": .string("/etc")])
        }

        _ = handle(payload, reply: decision(#"{"decision":"allow"}"#))

        let message = try XCTUnwrap(sent.only)
        XCTAssertEqual(message["tool_name"]?.stringValue, "external_directory")
        XCTAssertEqual(
            message["summary"]?.stringValue,
            "approve a external directory operation"
        )
        XCTAssertEqual(
            message["detail"]?.stringValue,
            "Approve a external directory operation"
        )
        // The raw metadata still reaches the broker as request context; only speech is
        // restricted to the kind name.
        XCTAssertEqual(message["tool_input"]?["path"]?.stringValue, "/etc")
    }

    func testPermissionAskedAcceptsAbsentOptionalFields() throws {
        let payload = try RelayFixture.permissionAsked { object in
            object["directory"] = .null
            object.removeValue(forKey: "metadata")
        }

        let result = handle(payload, reply: decision(#"{"decision":"allow"}"#))

        let message = try XCTUnwrap(sent.only)
        XCTAssertEqual(message["cwd"], .null)
        XCTAssertEqual(message["tool_input"]?.objectValue?.isEmpty, true)
        XCTAssertEqual(message["summary"]?.stringValue, "run a command")
        XCTAssertNotNil(result.stdout)
    }

    // MARK: - permission.asked fail-open

    func testAskDecisionLeavesOpenCodesPromptInControl() throws {
        let result = handle(
            Data(RelayFixture.permissionAsked.utf8),
            reply: decision(#"{"decision":"ask"}"#)
        )

        XCTAssertEqual(result, OpenCodeHookShim.passThrough)
        XCTAssertEqual(sent.count, 1)
    }

    func testBrokerErrorMalformedReplyAndTransportFailureAllFailOpen() throws {
        struct Timeout: Error {}

        XCTAssertEqual(
            handle(
                Data(RelayFixture.permissionAsked.utf8),
                reply: decision(#"{"error":"unauthorized"}"#)
            ),
            OpenCodeHookShim.passThrough
        )
        XCTAssertEqual(
            handle(Data(RelayFixture.permissionAsked.utf8), reply: decision("not json")),
            OpenCodeHookShim.passThrough
        )
        XCTAssertEqual(
            handle(Data(RelayFixture.permissionAsked.utf8), reply: decision("{}")),
            OpenCodeHookShim.passThrough
        )
        XCTAssertEqual(
            OpenCodeHookShim.handle(stdinData: Data(RelayFixture.permissionAsked.utf8)) { _, _ in
                throw Timeout()
            },
            OpenCodeHookShim.passThrough
        )
    }

    func testInvalidRelayInputNeverReachesTheBroker() throws {
        assertNoBrokerTraffic(Data("not json".utf8), "unparsable stdin")
        assertNoBrokerTraffic(Data("[]".utf8), "non-object stdin")
        assertNoBrokerTraffic(Data("".utf8), "empty stdin")
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0.removeValue(forKey: "tapq_relay_version") },
            "missing relay version"
        )
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0["tapq_relay_version"] = .number(2) },
            "future relay version"
        )
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0["tapq_relay_version"] = .string("1") },
            "non-numeric relay version"
        )
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0["hook_event_name"] = .string("permission.replied") },
            "unmanaged event"
        )
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0["session_id"] = .string("  ") },
            "blank session id"
        )
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0.removeValue(forKey: "permission_id") },
            "missing permission id"
        )
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0.removeValue(forKey: "permission") },
            "missing permission kind"
        )
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0["metadata"] = .string("not an object") },
            "non-object metadata"
        )
        assertNoBrokerTraffic(
            try RelayFixture.permissionAsked { $0["directory"] = .number(7) },
            "non-string directory"
        )
    }

    // MARK: - session.idle

    func testSessionIdleSendsAStopNotificationAndStaysSilent() throws {
        let result = handle(Data(RelayFixture.sessionIdle.utf8), reply: decision(#"{"ok":true}"#))

        let message = try XCTUnwrap(sent.only)
        XCTAssertEqual(message["type"]?.stringValue, WireType.notification)
        XCTAssertEqual(message["agent"]?["id"]?.stringValue, "opencode")
        XCTAssertEqual(message["session_id"]?.stringValue, "ses_01K7Q0000000000000000001")
        XCTAssertEqual(message["event"]?.stringValue, "stop")
        XCTAssertEqual(message["summary"], .null)
        XCTAssertEqual(timeouts, [OpenCodeHookShim.notifyTimeout])
        XCTAssertEqual(result, OpenCodeHookShim.passThrough)
    }

    func testSessionIdleStaysSilentWhenTheBrokerIsUnreachable() throws {
        struct Unreachable: Error {}

        let result = OpenCodeHookShim.handle(
            stdinData: Data(RelayFixture.sessionIdle.utf8)
        ) { _, _ in throw Unreachable() }

        XCTAssertEqual(result, OpenCodeHookShim.passThrough)
    }

    func testSessionIdleWithoutASessionNeverReachesTheBroker() throws {
        assertNoBrokerTraffic(
            Data(#"{"tapq_relay_version":1,"hook_event_name":"session.idle","directory":null}"#.utf8),
            "missing session id"
        )
    }

    // MARK: - Contract constants

    func testTimingChainKeepsTheBrokerBudgetIntact() {
        XCTAssertEqual(OpenCodeHookShim.approvalTimeout, InteractionBudget.shimSocketTimeout)
        XCTAssertGreaterThan(OpenCodeHookShim.approvalTimeout, InteractionBudget.total)
        XCTAssertEqual(OpenCodeHookShim.relayVersion, 1)
        XCTAssertEqual(OpenCodeHookShim.relayVersion, OpenCodePluginSource.version)
    }
}

extension Array {
    /// The single element, or nil when the array does not hold exactly one.
    var only: Element? { count == 1 ? first : nil }
}
