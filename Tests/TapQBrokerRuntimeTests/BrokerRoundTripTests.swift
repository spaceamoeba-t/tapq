import XCTest
@testable import TapQBrokerRuntime
import TapQContracts
import TapQPOSIXBridgeClient
import TapQWireProtocol

@MainActor
final class BrokerRoundTripTests: XCTestCase {
    private let socketPath = "/tmp/tapq-test-\(UUID().uuidString).sock"
    private lazy var transport = UnixSocketTransport(path: socketPath)

    private func send(_ json: String, timeout: TimeInterval = 2) async throws -> BrokerResponse {
        let path = socketPath
        let payload = Data(json.utf8)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try UnixSocketClient.request(payload, socketPath: path, timeout: timeout)
                })
            }
        }
        return try JSONDecoder().decode(BrokerResponse.self, from: data)
    }

    private func waitUntil(
        attempts: Int = 300,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    func testApprovalCarriesNormalizedAgentPresentation() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: {
                received.request = $0
                return .allow
            },
            onNotification: { _ in }
        )
        try server.start()
        let socketMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(socketMode & 0o777, 0o600)

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"agent":{"id":"codex","display_name":"Codex"},"session_id":"s","tool_name":"shell","tool_input":{"command":"swift test"},"summary":"run the test suite","detail":"swift test","approval_source":"pre_tool_use","request_id":"r1"}"#
        )

        XCTAssertEqual(response, .decision(.allow, reason: nil))
        XCTAssertEqual(received.request?.agent, .init(id: "codex", displayName: "Codex"))
        XCTAssertEqual(received.request?.summary, "run the test suite")
        XCTAssertEqual(received.request?.detail, "swift test")
    }

    func testApprovalWithoutPresentationUsesNeutralFallback() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .ask },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"session_id":"s","tool_name":"Bash","tool_input":{},"approval_source":"pre_tool_use","request_id":"r1"}"#
        )

        XCTAssertEqual(response, .decision(.ask, reason: nil))
        XCTAssertEqual(received.request?.agent, .unknown)
        XCTAssertEqual(received.request?.summary, "use Bash")
    }

    func testApprovalCarriesToolInputAndEnvironmentContext() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .allow },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"session_id":"s","cwd":"/Users/dev/project","tool_name":"Bash","tool_input":{"command":"rm -rf build","timeout":120,"sandbox":false},"permission_mode":"default","approval_source":"permission_request","request_id":"r1"}"#
        )

        XCTAssertEqual(response, .decision(.allow, reason: nil))
        let request = try XCTUnwrap(received.request)
        XCTAssertEqual(request.toolInput?["command"]?.stringValue, "rm -rf build")
        XCTAssertEqual(request.toolInput?["timeout"]?.intValue, 120)
        XCTAssertEqual(request.toolInput?["sandbox"]?.boolValue, false)
        XCTAssertEqual(request.cwd, "/Users/dev/project")
        XCTAssertEqual(request.permissionMode, "default")
        XCTAssertEqual(request.approvalSource, .permissionRequest)
    }

    func testApprovalWithoutContextFieldsSeparatesAbsentFromEmpty() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .ask },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"session_id":"s","tool_name":"Bash","tool_input":{},"approval_source":"pre_tool_use","request_id":"r1"}"#
        )

        XCTAssertEqual(response, .decision(.ask, reason: nil))
        let request = try XCTUnwrap(received.request)
        XCTAssertEqual(request.toolInput, [:], "an empty tool_input is still a known, empty input")
        XCTAssertNil(request.cwd)
        XCTAssertNil(request.permissionMode)
        XCTAssertEqual(request.approvalSource, .preToolUse)
    }

    func testApprovalContextNeverReachesBrokerDiagnostics() async throws {
        defer { transport.stop() }
        let diagnostics = RecordingSink()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            diagnosticSink: diagnostics,
            onApproval: { _ in .allow },
            onNotification: { _ in }
        )
        try server.start()

        _ = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"session_id":"s","cwd":"/Users/dev/private-notes","tool_name":"Bash","tool_input":{"command":"cat ~/.aws/credentials"},"permission_mode":"default","approval_source":"pre_tool_use","request_id":"r1"}"#
        )

        let recorded = diagnostics.events.flatMap {
            [$0.category, $0.name] + Array($0.fields.keys) + Array($0.fields.values)
        }
        for secret in ["private-notes", "cat ~/.aws/credentials", "credentials"] {
            XCTAssertFalse(
                recorded.contains { $0.contains(secret) },
                "approval context must stay in process, but \(secret) reached diagnostics"
            )
        }
        XCTAssertTrue(diagnostics.events.contains { $0.name == "approval.received" })
    }

    func testMissingApprovalSourceIsRejectedWithoutCallingHandler() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let diagnostics = RecordingSink()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            diagnosticSink: diagnostics,
            onApproval: { received.request = $0; return .deny },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"session_id":"s","tool_name":"Bash","tool_input":{},"request_id":"r1"}"#
        )

        XCTAssertEqual(response, .error("approval_source"))
        XCTAssertNil(received.request)
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "Broker"
                && $0.name == "request.rejected"
                && $0.level == .warning
                && $0.fields["reason"] == "approval_source"
        })
    }

    func testMissingApprovalSourceInAutoModeIsRejectedWithoutCallingHandler() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .deny },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"session_id":"s","tool_name":"Bash","tool_input":{},"permission_mode":"auto","request_id":"r1"}"#
        )

        XCTAssertEqual(response, .error("approval_source"))
        XCTAssertNil(received.request)
    }

    func testExplicitPreToolUseApprovalInAutoModePassesWithoutCallingHandler() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .deny },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"session_id":"s","tool_name":"Bash","tool_input":{},"permission_mode":"auto","approval_source":"pre_tool_use","request_id":"r1"}"#
        )

        XCTAssertEqual(response, .decision(.allow, reason: nil))
        XCTAssertNil(received.request)
    }

    func testPermissionRequestApprovalInAutoModeAlwaysCallsHandler() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .deny },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":3,"session_id":"s","tool_name":"Bash","tool_input":{},"permission_mode":"auto","approval_source":"permission_request","request_id":"r1"}"#
        )

        XCTAssertEqual(response, .decision(.deny, reason: "Denied via TapQ"))
        XCTAssertEqual(received.request?.toolName, "Bash")
        XCTAssertEqual(received.request?.id, "r1")
    }

    func testBadTokenNeverReachesApprovalHandler() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .allow },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"wrong","protocol_version":3,"session_id":"s","tool_name":"Bash","tool_input":{},"request_id":"r1"}"#
        )

        XCTAssertEqual(response, .error("unauthorized"))
        XCTAssertNil(received.request)
    }

    func testProtocolMismatchIsRejected() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .allow },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":999,"session_id":"s","tool_name":"Bash","tool_input":{},"request_id":"r1"}"#
        )
        XCTAssertEqual(response, .error("protocol_version"))
        XCTAssertNil(received.request, "protocol validation must precede approval-source validation")
    }

    func testV2NativeApprovalCannotBeSilentlyAutoPassedByV3Broker() async throws {
        defer { transport.stop() }
        let received = ApprovalBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { received.request = $0; return .allow },
            onNotification: { _ in }
        )
        try server.start()

        let response = try await send(
            #"{"type":"approval.request","token":"tok","protocol_version":2,"session_id":"s","tool_name":"Bash","tool_input":{},"permission_mode":"auto","approval_source":"permission_request","request_id":"r1"}"#
        )

        XCTAssertEqual(response, .error("protocol_version"))
        XCTAssertNil(received.request, "stale native-policy traffic must never reach approval policy")
    }

    func testNotificationIncludesAgentIdentity() async throws {
        defer { transport.stop() }
        let received = NotificationBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { received.notification = $0 }
        )
        try server.start()

        let response = try await send(
            #"{"type":"notification.event","token":"tok","protocol_version":3,"agent":{"id":"codex","display_name":"Codex"},"session_id":"s","event":"stop"}"#
        )

        XCTAssertEqual(response, .ok)
        XCTAssertEqual(received.notification?.kind, .finished)
        XCTAssertEqual(received.notification?.agent.id, "codex")
    }

    func testSelectionReturnsHandlerChoice() async throws {
        defer { transport.stop() }
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onSelection: { request in
                SelectionResult(choices: [.init(index: 1, label: request.options[1].label)])
            }
        )
        try server.start()

        let response = try await send(
            #"{"type":"selection.request","token":"tok","protocol_version":3,"session_id":"s","request_id":"r1","question":"Pick","options":[{"label":"A","description":"a"},{"label":"B","description":"b"}],"multi_select":false}"#
        )
        XCTAssertEqual(response, .selection(indices: [1], labels: ["B"]))
    }

    func testStopQuestionRoundTrip() async throws {
        defer { transport.stop() }
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onStopQuestion: { "answered for \($0.agent.displayName)" }
        )
        try server.start()

        let response = try await send(
            #"{"type":"stop.question","token":"tok","protocol_version":3,"agent":{"id":"codex","display_name":"Codex"},"session_id":"s","request_id":"r1","text":"Continue?"}"#
        )
        XCTAssertEqual(response, .stopQuestion(reply: "answered for Codex"))
    }

    func testConcurrentDuplicateStopQuestionsShareOneInteraction() async throws {
        defer { transport.stop() }
        let received = StopQuestionBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onStopQuestion: { _ in
                received.calls += 1
                try? await Task.sleep(nanoseconds: 75_000_000)
                return "selected option 1"
            }
        )
        try server.start()

        async let first = send(
            #"{"type":"stop.question","token":"tok","protocol_version":3,"agent":{"id":"claude-code","display_name":"Claude Code"},"session_id":"same-session","request_id":"hook-1","text":"Choose A or B?"}"#
        )
        async let second = send(
            #"{"type":"stop.question","token":"tok","protocol_version":3,"agent":{"id":"claude-code","display_name":"Claude Code"},"session_id":"same-session","request_id":"hook-2","text":"Choose A or B?"}"#
        )
        let (firstResponse, secondResponse) = try await (first, second)

        XCTAssertEqual(firstResponse, .stopQuestion(reply: "selected option 1"))
        XCTAssertEqual(secondResponse, .stopQuestion(reply: "selected option 1"))
        XCTAssertEqual(received.calls, 1)
    }

    func testDisconnectedClientDoesNotTerminateBroker() async throws {
        defer { transport.stop() }
        let received = StopQuestionBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onStopQuestion: { question in
                received.calls += 1
                if question.text == "Slow response?" {
                    try? await Task.sleep(nanoseconds: 75_000_000)
                }
                received.completed += 1
                return "handled \(question.text)"
            }
        )
        try server.start()

        do {
            _ = try await send(
                #"{"type":"stop.question","token":"tok","protocol_version":3,"session_id":"s","request_id":"slow","text":"Slow response?"}"#,
                timeout: 0.01
            )
            XCTFail("the deliberately slow response should exceed the client timeout")
        } catch {
            // The peer disconnect is the condition under test; the broker must survive it.
        }

        let didFinishSlowResponse = await waitUntil { received.completed == 1 }
        XCTAssertTrue(didFinishSlowResponse)

        let response = try await send(
            #"{"type":"stop.question","token":"tok","protocol_version":3,"session_id":"s","request_id":"healthy","text":"Still running?"}"#
        )
        XCTAssertEqual(response, .stopQuestion(reply: "handled Still running?"))
        XCTAssertEqual(received.calls, 2)
        XCTAssertEqual(received.completed, 2)
    }

    func testRecentlyCompletedStopQuestionReplaysButDifferentTextDoesNot() async throws {
        defer { transport.stop() }
        let received = StopQuestionBox()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onStopQuestion: { question in
                received.calls += 1
                return "answer for \(question.text)"
            }
        )
        try server.start()

        let first = try await send(
            #"{"type":"stop.question","token":"tok","protocol_version":3,"session_id":"s","request_id":"r1","text":"Continue?"}"#
        )
        let replay = try await send(
            #"{"type":"stop.question","token":"tok","protocol_version":3,"session_id":"s","request_id":"r2","text":"Continue?"}"#
        )
        let distinct = try await send(
            #"{"type":"stop.question","token":"tok","protocol_version":3,"session_id":"s","request_id":"r3","text":"Deploy now?"}"#
        )

        XCTAssertEqual(first, .stopQuestion(reply: "answer for Continue?"))
        XCTAssertEqual(replay, first)
        XCTAssertEqual(distinct, .stopQuestion(reply: "answer for Deploy now?"))
        XCTAssertEqual(received.calls, 2)
    }

    @MainActor private final class ApprovalBox {
        var request: ApprovalRequest?
    }

    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @MainActor private final class NotificationBox {
        var notification: AgentNotification?
    }

    @MainActor private final class StopQuestionBox {
        var calls = 0
        var completed = 0
    }
}
