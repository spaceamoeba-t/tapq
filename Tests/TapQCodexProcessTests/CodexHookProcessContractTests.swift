import Foundation
import TapQBrokerRuntime
import TapQContracts
import TapQWireProtocol
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@MainActor
final class CodexHookProcessContractTests: XCTestCase {
    func testCodex01460RequestUserInputReachesBrokerAndBlocksWithSelection() async throws {
        let hookExecutable = try hookExecutableURL()
        let testRoot = try makeTestRoot()

        let discovery = BrokerRuntimeDiscovery(supportDirectory: testRoot)
        try discovery.prepareDirectory()
        let token = BrokerRuntimeDiscovery.generateToken()
        let transport = UnixSocketTransport(path: discovery.socketPath)
        let recorder = SelectionRecorder()
        let server = BrokerServer(
            transport: transport,
            token: token,
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onSelection: { request in
                recorder.requests.append(request)
                return SelectionResult(choices: [
                    .init(index: 1, label: request.options[1].label),
                ])
            }
        )
        try server.start()
        try discovery.publish(token: token)
        defer {
            server.stop()
            discovery.remove()
            try? FileManager.default.removeItem(at: testRoot)
        }

        let fixture = try fixtureData(
            named: "pre-tool-use-request-user-input-single-choice"
        )
        let fixtureObject = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: fixture
        )
        XCTAssertEqual(
            Set(fixtureObject.keys),
            [
                "session_id", "turn_id", "transcript_path", "cwd",
                "hook_event_name", "model", "permission_mode", "tool_name",
                "tool_input", "tool_use_id",
            ],
            "the versioned root fixture must preserve the exact Codex 0.146 envelope"
        )
        XCTAssertNil(fixtureObject["agent_id"])
        XCTAssertNil(fixtureObject["agent_type"])
        XCTAssertNil(fixtureObject["request_id"])

        let processResult = try await runHook(
            executable: hookExecutable,
            fixture: fixture,
            testRoot: testRoot
        )
        XCTAssertEqual(processResult.terminationStatus, 0)
        XCTAssertTrue(
            processResult.stderr.isEmpty,
            "unexpected hook stderr: "
                + String(decoding: processResult.stderr, as: UTF8.self)
        )

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: processResult.stdout
        )
        let hookOutput = try XCTUnwrap(output["hookSpecificOutput"]?.objectValue)
        XCTAssertEqual(Set(output.keys), ["hookSpecificOutput"])
        XCTAssertEqual(
            Set(hookOutput.keys),
            ["hookEventName", "permissionDecision", "permissionDecisionReason"]
        )
        XCTAssertEqual(hookOutput["hookEventName"]?.stringValue, "PreToolUse")
        XCTAssertEqual(hookOutput["permissionDecision"]?.stringValue, "deny")
        XCTAssertEqual(
            hookOutput["permissionDecisionReason"]?.stringValue,
            "User answered via TapQ hands-free interface. Treat this request_user_input "
                + "call as successful with response JSON: "
                + #"{"answers":{"choice":{"answers":["BETA"]}}}"#
                + ". Do not re-ask this question."
        )

        let request = try XCTUnwrap(recorder.requests.only)
        XCTAssertEqual(request.sessionID, "019fb3cc-0000-7000-8000-000000000001")
        XCTAssertEqual(request.id, "call_fixture_request_user_input_001")
        XCTAssertEqual(request.agent, .codex)
        XCTAssertEqual(request.question, "Choose a value.")
        XCTAssertEqual(
            request.options,
            [
                .init(label: "ALPHA", description: "First choice"),
                .init(label: "BETA", description: "Second choice"),
                .init(label: "GAMMA", description: "Third choice"),
            ]
        )
        XCTAssertFalse(request.multiSelect)
    }

    func testCodex01460UserPromptSubmitWithLiveSteeringEmitsContextWithoutBrokerRequest() async throws {
        let fixture = try fixtureData(named: "user-prompt-submit-root")
        let fixtureObject = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: fixture
        )
        XCTAssertEqual(
            Set(fixtureObject.keys),
            [
                "session_id", "turn_id", "transcript_path", "cwd",
                "hook_event_name", "model", "permission_mode", "prompt",
            ],
            "the source-derived fixture must preserve the exact Codex 0.146 envelope"
        )
        XCTAssertNil(fixtureObject["agent_id"])
        XCTAssertNil(fixtureObject["agent_type"])

        let callbacks = BrokerCallbackRecorder()
        let diagnostics = ProcessDiagnosticRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            discoveryOverride: .steeringEnabled,
            diagnosticSink: diagnostics,
            onApproval: { _ in
                callbacks.events.append("approval")
                return .ask
            },
            onNotification: { _ in callbacks.events.append("notification") },
            onSelection: { _ in
                callbacks.events.append("selection")
                return .noSelection
            },
            onStopQuestion: { _ in
                callbacks.events.append("stop_question")
                return nil
            }
        )
        assertCleanExit(processResult)

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: processResult.stdout
        )
        XCTAssertEqual(output, [
            "hookSpecificOutput": .object([
                "hookEventName": .string("UserPromptSubmit"),
                "additionalContext": .string(
                    "When you need the user to choose between options or confirm a decision, "
                        + "use request_user_input when available rather than asking in plain text."
                ),
            ]),
        ])
        XCTAssertTrue(callbacks.events.isEmpty)
        XCTAssertEqual(
            diagnostics.events.map(\.name),
            ["started", "stopped"],
            "UserPromptSubmit steering must read discovery without sending a broker request"
        )
    }

    func testCodex01460UserPromptSubmitWithSteeringDisabledFailsOpen() async throws {
        let callbacks = BrokerCallbackRecorder()
        let diagnostics = ProcessDiagnosticRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixtureData(named: "user-prompt-submit-root"),
            diagnosticSink: diagnostics,
            onApproval: { _ in
                callbacks.events.append("approval")
                return .ask
            },
            onNotification: { _ in callbacks.events.append("notification") },
            onSelection: { _ in
                callbacks.events.append("selection")
                return .noSelection
            },
            onStopQuestion: { _ in
                callbacks.events.append("stop_question")
                return nil
            }
        )

        assertFailOpen(processResult)
        XCTAssertTrue(callbacks.events.isEmpty)
        XCTAssertEqual(diagnostics.events.map(\.name), ["started", "stopped"])
    }

    func testCodex01460UserPromptSubmitWithMissingDiscoveryFailsOpen() async throws {
        let hookExecutable = try hookExecutableURL()
        let testRoot = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let processResult = try await runHook(
            executable: hookExecutable,
            fixture: fixtureData(named: "user-prompt-submit-root"),
            testRoot: testRoot
        )

        assertFailOpen(processResult)
    }

    func testCodex01460UserPromptSubmitWithStaleDiscoveryFailsOpen() async throws {
        let callbacks = BrokerCallbackRecorder()
        let diagnostics = ProcessDiagnosticRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixtureData(named: "user-prompt-submit-root"),
            discoveryOverride: .staleSteering,
            diagnosticSink: diagnostics,
            onApproval: { _ in
                callbacks.events.append("approval")
                return .ask
            },
            onNotification: { _ in callbacks.events.append("notification") },
            onSelection: { _ in
                callbacks.events.append("selection")
                return .noSelection
            },
            onStopQuestion: { _ in
                callbacks.events.append("stop_question")
                return nil
            }
        )

        assertFailOpen(processResult)
        XCTAssertTrue(callbacks.events.isEmpty)
        XCTAssertEqual(diagnostics.events.map(\.name), ["started", "stopped"])
    }

    func testCodex01460UserPromptSubmitWithIncompatibleDiscoveryFailsOpen() async throws {
        let callbacks = BrokerCallbackRecorder()
        let diagnostics = ProcessDiagnosticRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixtureData(named: "user-prompt-submit-root"),
            discoveryOverride: .steeringProtocolVersion(WireProtocol.version + 1),
            diagnosticSink: diagnostics,
            onApproval: { _ in
                callbacks.events.append("approval")
                return .ask
            },
            onNotification: { _ in callbacks.events.append("notification") },
            onSelection: { _ in
                callbacks.events.append("selection")
                return .noSelection
            },
            onStopQuestion: { _ in
                callbacks.events.append("stop_question")
                return nil
            }
        )

        assertFailOpen(processResult)
        XCTAssertTrue(callbacks.events.isEmpty)
        XCTAssertEqual(diagnostics.events.map(\.name), ["started", "stopped"])
    }

    func testCodex01460MCPPermissionRequestReachesBrokerAndAllows() async throws {
        let hookExecutable = try hookExecutableURL()
        let testRoot = try makeTestRoot()

        let discovery = BrokerRuntimeDiscovery(supportDirectory: testRoot)
        try discovery.prepareDirectory()
        let token = BrokerRuntimeDiscovery.generateToken()
        let transport = UnixSocketTransport(path: discovery.socketPath)
        let recorder = ApprovalRecorder()
        let server = BrokerServer(
            transport: transport,
            token: token,
            onApproval: { request in
                recorder.requests.append(request)
                return .allow
            },
            onNotification: { _ in }
        )
        try server.start()
        try discovery.publish(token: token)
        defer {
            server.stop()
            discovery.remove()
            try? FileManager.default.removeItem(at: testRoot)
        }

        let fixture = try fixtureData(
            named: "permission-request-mcp-memory-create-entities"
        )
        let fixtureObject = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: fixture
        )
        XCTAssertEqual(
            Set(fixtureObject.keys),
            [
                "session_id", "turn_id", "transcript_path", "cwd",
                "hook_event_name", "model", "permission_mode", "tool_name",
                "tool_input",
            ],
            "the source-derived fixture must preserve the exact Codex 0.146 envelope"
        )
        for absentKey in [
            "agent_id", "agent_type", "tool_use_id", "request_id", "call_id",
            "run_id_suffix",
        ] {
            XCTAssertNil(fixtureObject[absentKey])
        }

        let processResult = try await runHook(
            executable: hookExecutable,
            fixture: fixture,
            testRoot: testRoot
        )
        XCTAssertEqual(processResult.terminationStatus, 0)
        XCTAssertTrue(
            processResult.stderr.isEmpty,
            "unexpected hook stderr: "
                + String(decoding: processResult.stderr, as: UTF8.self)
        )

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: processResult.stdout
        )
        XCTAssertEqual(output, [
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object([
                    "behavior": .string("allow"),
                ]),
            ]),
        ])

        let request = try XCTUnwrap(recorder.requests.only)
        XCTAssertEqual(request.sessionID, "019fb3cc-0000-7000-8000-000000000003")
        XCTAssertFalse(request.id.isEmpty)
        XCTAssertNotNil(
            UUID(uuidString: request.id),
            "PermissionRequest has no call ID, so the hook must generate a UUID request ID"
        )
        XCTAssertEqual(request.agent, .codex)
        XCTAssertEqual(request.toolName, "mcp__memory__create_entities")
        XCTAssertEqual(request.toolInput, [
            "entities": .array([
                .object([
                    "name": .string("Ada"),
                    "entityType": .string("person"),
                ]),
            ]),
        ])
        XCTAssertEqual(request.cwd, "/tmp/tapq-codex-fixture-workspace")
        XCTAssertEqual(request.permissionMode, "default")
        XCTAssertEqual(request.approvalSource, .permissionRequest)
        XCTAssertEqual(request.kind, .toolApproval)
        XCTAssertEqual(request.summary, "use create entities from memory")
        XCTAssertEqual(request.detail, "Use create entities from the memory MCP server")
        for argumentValue in ["Ada", "person"] {
            XCTAssertFalse(request.summary.contains(argumentValue))
            XCTAssertFalse(request.detail.contains(argumentValue))
        }
    }

    func testCodex01425PermissionRequestEnvelopeReachesBrokerAndAllows() async throws {
        let fixture = try fixtureData(
            version: "0.142.5",
            named: "permission-request-bash"
        )
        let fixtureObject = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: fixture
        )
        XCTAssertEqual(
            Set(fixtureObject.keys),
            [
                "session_id", "turn_id", "transcript_path", "cwd",
                "hook_event_name", "model", "permission_mode", "tool_name",
                "tool_input",
            ],
            "the source-derived fixture must preserve the exact Codex 0.142.5 envelope"
        )
        for absentKey in [
            "agent_id", "agent_type", "tool_use_id", "request_id", "call_id",
            "approval_attempt", "sandbox_permissions", "additional_permissions",
            "justification", "host", "protocol",
        ] {
            XCTAssertNil(fixtureObject[absentKey])
        }

        let recorder = ApprovalRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            onApproval: { request in
                recorder.requests.append(request)
                return .allow
            }
        )
        assertCleanExit(processResult)

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: processResult.stdout
        )
        XCTAssertEqual(output, permissionRequestOutput(behavior: "allow"))

        let request = try XCTUnwrap(recorder.requests.only)
        XCTAssertEqual(request.sessionID, "019fb425-0000-7000-8000-000000000001")
        XCTAssertNotNil(UUID(uuidString: request.id))
        XCTAssertEqual(request.agent, .codex)
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.toolInput, [
            "command": .string("rm -f /tmp/tapq-codex-0.142.5-marker"),
        ])
        XCTAssertEqual(request.cwd, "/tmp/tapq-codex-0.142.5-fixture-workspace")
        XCTAssertEqual(request.permissionMode, "default")
        XCTAssertEqual(request.approvalSource, .permissionRequest)
    }

    func testCodex01460MCPPermissionRequestReachesBrokerAndDenies() async throws {
        let fixture = try fixtureData(
            named: "permission-request-mcp-memory-create-entities"
        )
        let recorder = ApprovalRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            onApproval: { request in
                recorder.requests.append(request)
                return .deny
            }
        )
        assertCleanExit(processResult)

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: processResult.stdout
        )
        XCTAssertEqual(
            output,
            permissionRequestOutput(
                behavior: "deny",
                message: "Denied via TapQ"
            )
        )
        XCTAssertEqual(recorder.requests.only?.toolName, "mcp__memory__create_entities")
    }

    func testCodex01460MCPBrokerAskFailsOpenToNativePrompt() async throws {
        let fixture = try fixtureData(
            named: "permission-request-mcp-memory-create-entities"
        )
        let recorder = ApprovalRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            onApproval: { request in
                recorder.requests.append(request)
                return .ask
            }
        )

        assertFailOpen(processResult)
        XCTAssertEqual(recorder.requests.only?.toolName, "mcp__memory__create_entities")
    }

    func testCodex01425StopQuestionReachesBrokerAndReturnsContinuation() async throws {
        let fixture = try fixtureData(version: "0.142.5", named: "stop-question")
        let fixtureObject = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: fixture
        )
        XCTAssertEqual(
            Set(fixtureObject.keys),
            [
                "session_id", "turn_id", "transcript_path", "cwd",
                "hook_event_name", "model", "permission_mode", "stop_hook_active",
                "last_assistant_message",
            ],
            "the source-derived fixture must preserve the exact Codex 0.142.5 Stop envelope"
        )
        XCTAssertNil(fixtureObject["agent_id"])
        XCTAssertNil(fixtureObject["agent_type"])

        let stopRecorder = StopQuestionRecorder()
        let notificationRecorder = NotificationRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            onNotification: { notificationRecorder.notifications.append($0) },
            onStopQuestion: { question in
                stopRecorder.questions.append(question)
                return "Yes. Run the migration."
            }
        )
        assertCleanExit(processResult)

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: processResult.stdout
        )
        XCTAssertEqual(output, [
            "decision": .string("block"),
            "reason": .string("Yes. Run the migration."),
        ])
        XCTAssertTrue(notificationRecorder.notifications.isEmpty)

        let question = try XCTUnwrap(stopRecorder.questions.only)
        XCTAssertEqual(question.sessionID, "019fb425-0000-7000-8000-000000000003")
        XCTAssertEqual(question.agent, .codex)
        XCTAssertEqual(question.text, "Would you like me to run the migration?")
    }

    func testCodex01425StopWithoutQuestionNotifiesCompletionAndFailsThrough() async throws {
        let fixture = try fixtureReplacing(
            version: "0.142.5",
            named: "stop-question",
            values: ["last_assistant_message": .string("Migration is complete.")]
        )
        let stopRecorder = StopQuestionRecorder()
        let notificationRecorder = NotificationRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            onNotification: { notificationRecorder.notifications.append($0) },
            onStopQuestion: { question in
                stopRecorder.questions.append(question)
                return "unexpected"
            }
        )

        assertFailOpen(processResult)
        XCTAssertTrue(stopRecorder.questions.isEmpty)
        let notification = try XCTUnwrap(notificationRecorder.notifications.only)
        XCTAssertEqual(notification.sessionID, "019fb425-0000-7000-8000-000000000003")
        XCTAssertEqual(notification.agent, .codex)
        XCTAssertEqual(notification.kind, .finished)
        XCTAssertNil(notification.summary)
    }

    func testCodex01425ActiveStopDoesNotRepeatQuestionAndFailsThrough() async throws {
        let fixture = try fixtureReplacing(
            version: "0.142.5",
            named: "stop-question",
            values: ["stop_hook_active": .bool(true)]
        )
        let stopRecorder = StopQuestionRecorder()
        let notificationRecorder = NotificationRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            onNotification: { notificationRecorder.notifications.append($0) },
            onStopQuestion: { question in
                stopRecorder.questions.append(question)
                return "unexpected"
            }
        )

        assertFailOpen(processResult)
        XCTAssertTrue(stopRecorder.questions.isEmpty)
        XCTAssertEqual(notificationRecorder.notifications.only?.kind, .finished)
    }

    func testPermissionRequestWithMissingDiscoveryFailsOpen() async throws {
        let hookExecutable = try hookExecutableURL()
        let testRoot = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let fixture = try fixtureData(
            version: "0.142.5",
            named: "permission-request-bash"
        )
        let processResult = try await runHook(
            executable: hookExecutable,
            fixture: fixture,
            testRoot: testRoot
        )

        assertFailOpen(processResult)
    }

    func testPermissionRequestWithIncompatibleDiscoveredWireVersionFailsOpen() async throws {
        let fixture = try fixtureData(
            version: "0.142.5",
            named: "permission-request-bash"
        )
        let recorder = ApprovalRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            discoveryOverride: .protocolVersion(WireProtocol.version + 1),
            onApproval: { request in
                recorder.requests.append(request)
                return .allow
            }
        )

        assertFailOpen(processResult)
        XCTAssertTrue(
            recorder.requests.isEmpty,
            "the hook must reject an incompatible discovery record before broker policy runs"
        )
    }

    func testPermissionRequestWithUnauthorizedDiscoveryTokenFailsOpen() async throws {
        let fixture = try fixtureData(
            version: "0.142.5",
            named: "permission-request-bash"
        )
        let recorder = ApprovalRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            discoveryOverride: .wrongToken,
            onApproval: { request in
                recorder.requests.append(request)
                return .allow
            }
        )

        assertFailOpen(processResult)
        XCTAssertTrue(
            recorder.requests.isEmpty,
            "the broker must reject the request before approval policy runs"
        )
    }

    private func makeTestRoot() throws -> URL {
        let testRoot = URL(
            fileURLWithPath: "/tmp/tapq-codex-contract-\(UUID().uuidString.prefix(12))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: true
        )
        return testRoot
    }

    private func fixtureData(
        version: String = "0.146.0",
        named name: String
    ) throws -> Data {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/codex-cli-\(version)"
        ))
        return try Data(contentsOf: fixtureURL)
    }

    private func fixtureReplacing(
        version: String,
        named name: String,
        values: [String: JSONValue]
    ) throws -> Data {
        var fixture = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: fixtureData(version: version, named: name)
        )
        for (key, value) in values {
            fixture[key] = value
        }
        return try JSONEncoder().encode(fixture)
    }

    private func runHookAgainstBroker(
        fixture: Data,
        discoveryOverride: DiscoveryOverride = .standard,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        onApproval: @escaping @MainActor (ApprovalRequest) async -> Decision = { _ in .ask },
        onNotification: @escaping @MainActor (AgentNotification) -> Void = { _ in },
        onSelection: @escaping @MainActor (SelectionRequest) async -> SelectionResult = {
            _ in .noSelection
        },
        onStopQuestion: @escaping @MainActor (StopQuestion) async -> String? = { _ in nil }
    ) async throws -> HookProcessResult {
        let hookExecutable = try hookExecutableURL()
        let testRoot = try makeTestRoot()
        let discovery = BrokerRuntimeDiscovery(supportDirectory: testRoot)
        try discovery.prepareDirectory()
        let serverToken = BrokerRuntimeDiscovery.generateToken()
        let server = BrokerServer(
            transport: UnixSocketTransport(path: discovery.socketPath),
            token: serverToken,
            diagnosticSink: diagnosticSink,
            onApproval: onApproval,
            onNotification: onNotification,
            onSelection: onSelection,
            onStopQuestion: onStopQuestion
        )
        try server.start()
        switch discoveryOverride {
        case .standard:
            try discovery.publish(token: serverToken)
        case .steeringEnabled:
            try discovery.publish(token: serverToken, steeringEnabled: true)
        case .wrongToken:
            try discovery.publish(token: "wrong-\(serverToken)")
        case .protocolVersion(let version):
            try publishDiscovery(
                discovery,
                token: serverToken,
                protocolVersion: version
            )
        case .steeringProtocolVersion(let version):
            try publishDiscovery(
                discovery,
                token: serverToken,
                protocolVersion: version,
                steeringEnabled: true
            )
        case .staleSteering:
            try publishDiscovery(
                discovery,
                token: serverToken,
                protocolVersion: WireProtocol.version,
                steeringEnabled: true,
                processID: Int32.max
            )
        }
        defer {
            server.stop()
            discovery.remove()
            try? FileManager.default.removeItem(at: testRoot)
        }

        return try await runHook(
            executable: hookExecutable,
            fixture: fixture,
            testRoot: testRoot
        )
    }

    private func publishDiscovery(
        _ discovery: BrokerRuntimeDiscovery,
        token: String,
        protocolVersion: Int,
        steeringEnabled: Bool = false,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let record: [String: JSONValue] = [
            "socket": .string(discovery.socketPath),
            "token": .string(token),
            "protocol_version": .number(Double(protocolVersion)),
            "steering_enabled": .bool(steeringEnabled),
            "process_id": .number(Double(processID)),
        ]
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)
        try data.write(to: discovery.discoveryURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: discovery.discoveryURL.path
        )
    }

    private func permissionRequestOutput(
        behavior: String,
        message: String? = nil
    ) -> [String: JSONValue] {
        var decision: [String: JSONValue] = ["behavior": .string(behavior)]
        if let message {
            decision["message"] = .string(message)
        }
        return [
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decision),
            ]),
        ]
    }

    private func assertCleanExit(
        _ result: HookProcessResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.terminationStatus, 0, file: file, line: line)
        XCTAssertTrue(
            result.stderr.isEmpty,
            "unexpected hook stderr: " + String(decoding: result.stderr, as: UTF8.self),
            file: file,
            line: line
        )
    }

    private func assertFailOpen(
        _ result: HookProcessResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertCleanExit(result, file: file, line: line)
        XCTAssertTrue(
            result.stdout.isEmpty,
            "fail-open must emit no stdout; got: "
                + String(decoding: result.stdout, as: UTF8.self),
            file: file,
            line: line
        )
    }

    private func runHook(
        executable: URL,
        fixture: Data,
        testRoot: URL
    ) async throws -> HookProcessResult {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = testRoot
        var environment = ProcessInfo.processInfo.environment
        environment["TAPQ_BROKER_DIR"] = testRoot.path
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: fixture)
        try stdin.fileHandleForWriting.close()

        let exited = await waitUntilExit(process, timeout: 5)
        if !exited {
            process.terminate()
            let terminated = await waitUntilExit(process, timeout: 1)
            if !terminated {
                forceTerminate(process)
                _ = await waitUntilExit(process, timeout: 1)
            }
            throw ContractTestError.hookTimedOut
        }

        return HookProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func hookExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment[
            "TAPQ_CODEX_HOOK_EXECUTABLE"
        ], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ContractTestError.hookIsNotExecutable(url.path)
            }
            return url
        }

        let testBundleURL = Bundle(for: Self.self).bundleURL
        let productsDirectory = testBundleURL.pathExtension == "xctest"
            ? testBundleURL.deletingLastPathComponent()
            : testBundleURL
        let candidate = productsDirectory.appendingPathComponent("tapq-codex-hook")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip(
                "tapq-codex-hook is not colocated with the test bundle; "
                    + "set TAPQ_CODEX_HOOK_EXECUTABLE to run this process contract"
            )
        }
        return candidate
    }

    private func waitUntilExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func forceTerminate(_ process: Process) {
        guard process.isRunning else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(process.processIdentifier, SIGKILL)
        #endif
    }
}

@MainActor
private final class SelectionRecorder {
    var requests: [SelectionRequest] = []
}

@MainActor
private final class ApprovalRecorder {
    var requests: [ApprovalRequest] = []
}

@MainActor
private final class StopQuestionRecorder {
    var questions: [StopQuestion] = []
}

@MainActor
private final class NotificationRecorder {
    var notifications: [AgentNotification] = []
}

@MainActor
private final class BrokerCallbackRecorder {
    var events: [String] = []
}

private final class ProcessDiagnosticRecorder: TapQDiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [TapQDiagnosticEvent] = []

    func record(_ event: TapQDiagnosticEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    var events: [TapQDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

private enum DiscoveryOverride {
    case standard
    case steeringEnabled
    case wrongToken
    case protocolVersion(Int)
    case steeringProtocolVersion(Int)
    case staleSteering
}

private struct HookProcessResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

private enum ContractTestError: Error {
    case hookIsNotExecutable(String)
    case hookTimedOut
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
