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

    private func fixtureData(named name: String) throws -> Data {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/codex-cli-0.146.0"
        ))
        return try Data(contentsOf: fixtureURL)
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
