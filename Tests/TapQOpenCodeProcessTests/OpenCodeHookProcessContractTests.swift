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

/// Drives `tapq-opencode-hook` as a real child process and, for broker-backed cases, sends
/// its authenticated request through the real Unix-socket transport to `BrokerServer`.
///
/// This is a **plugin-relay-to-broker process contract**, not an OpenCode end-to-end test.
/// It does not start OpenCode, load the installed plugin into OpenCode's runtime, or prove
/// that OpenCode accepted the permission reply the plugin then issues. Those boundaries
/// stay covered by upstream schema provenance and the manual test plan.
@MainActor
final class OpenCodeHookProcessContractTests: XCTestCase {
    func testPermissionAskedReachesTheBrokerAndReturnsAllow() async throws {
        let fixture = try fixtureData(named: "permission-asked-bash")
        let fixtureObject = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: fixture
        )
        XCTAssertEqual(
            Set(fixtureObject.keys),
            [
                "tapq_relay_version", "hook_event_name", "session_id",
                "permission_id", "permission", "metadata", "directory",
            ],
            "the relay fixture must preserve the exact envelope the installed plugin writes"
        )

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
        XCTAssertEqual(Set(output.keys), ["hookEventName", "decision"])
        XCTAssertEqual(output["hookEventName"]?.stringValue, "permission.asked")
        XCTAssertEqual(
            Set(try XCTUnwrap(output["decision"]?.objectValue).keys),
            ["behavior"]
        )
        XCTAssertEqual(output["decision"]?["behavior"]?.stringValue, "allow")

        let request = try XCTUnwrap(recorder.requests.only)
        XCTAssertEqual(request.sessionID, "ses_01K7Q0000000000000000001")
        XCTAssertEqual(request.id, "per_01K7Q0000000000000000002")
        XCTAssertEqual(request.agent, .openCode)
        XCTAssertEqual(request.toolName, "bash")
        XCTAssertEqual(request.approvalSource, .permissionRequest)
        XCTAssertEqual(request.summary, "run rm -rf build")
        XCTAssertEqual(request.toolInput?["command"]?.stringValue, "rm -rf build")
    }

    func testPermissionAskedReturnsDenyWithTheBrokersReason() async throws {
        let fixture = try fixtureData(named: "permission-asked-bash")
        let processResult = try await runHookAgainstBroker(
            fixture: fixture,
            onApproval: { _ in .deny }
        )
        assertCleanExit(processResult)

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: processResult.stdout
        )
        XCTAssertEqual(output["decision"]?["behavior"]?.stringValue, "deny")
        XCTAssertNotNil(output["decision"]?["message"]?.stringValue)
    }

    func testAskDecisionLeavesOpenCodesPromptInControl() async throws {
        let processResult = try await runHookAgainstBroker(
            fixture: try fixtureData(named: "permission-asked-bash"),
            onApproval: { _ in .ask }
        )
        assertFailOpen(processResult)
    }

    func testSessionIdleDeliversACompletionNotificationSilently() async throws {
        let recorder = NotificationRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: try fixtureData(named: "session-idle"),
            onNotification: { recorder.notifications.append($0) }
        )
        assertFailOpen(processResult)

        let notification = try XCTUnwrap(recorder.notifications.only)
        XCTAssertEqual(notification.sessionID, "ses_01K7Q0000000000000000001")
        XCTAssertEqual(notification.agent, .openCode)
        XCTAssertEqual(notification.kind, .finished)
    }

    func testAbsentBrokerFailsOpenWithoutHangingOpenCode() async throws {
        let hookExecutable = try hookExecutableURL()
        let testRoot = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let processResult = try await runHook(
            executable: hookExecutable,
            fixture: try fixtureData(named: "permission-asked-bash"),
            testRoot: testRoot
        )
        assertFailOpen(processResult)
    }

    func testUnauthorizedDiscoveryTokenFailsOpenBeforeApprovalPolicyRuns() async throws {
        let recorder = ApprovalRecorder()
        let processResult = try await runHookAgainstBroker(
            fixture: try fixtureData(named: "permission-asked-bash"),
            useWrongToken: true,
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

    func testMismatchedRelayVersionNeverReachesTheBroker() async throws {
        let recorder = ApprovalRecorder()
        var fixture = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: try fixtureData(named: "permission-asked-bash")
        )
        fixture["tapq_relay_version"] = .number(99)

        let processResult = try await runHookAgainstBroker(
            fixture: try JSONEncoder().encode(fixture),
            onApproval: { request in
                recorder.requests.append(request)
                return .allow
            }
        )

        assertFailOpen(processResult)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    // MARK: - Harness

    private func makeTestRoot() throws -> URL {
        let testRoot = URL(
            fileURLWithPath: "/tmp/tapq-opencode-contract-\(UUID().uuidString.prefix(12))",
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
            subdirectory: "Fixtures/opencode-1.18.15"
        ))
        return try Data(contentsOf: fixtureURL)
    }

    private func runHookAgainstBroker(
        fixture: Data,
        useWrongToken: Bool = false,
        onApproval: @escaping @MainActor (ApprovalRequest) async -> Decision = { _ in .ask },
        onNotification: @escaping @MainActor (AgentNotification) -> Void = { _ in }
    ) async throws -> HookProcessResult {
        let hookExecutable = try hookExecutableURL()
        let testRoot = try makeTestRoot()
        let discovery = BrokerRuntimeDiscovery(supportDirectory: testRoot)
        try discovery.prepareDirectory()
        let serverToken = BrokerRuntimeDiscovery.generateToken()
        let server = BrokerServer(
            transport: UnixSocketTransport(path: discovery.socketPath),
            token: serverToken,
            onApproval: onApproval,
            onNotification: onNotification,
            onSelection: { _ in .noSelection },
            onStopQuestion: { _ in nil }
        )
        try server.start()
        try discovery.publish(token: useWrongToken ? "wrong-\(serverToken)" : serverToken)
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
            "TAPQ_OPENCODE_HOOK_EXECUTABLE"
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
        let candidate = productsDirectory.appendingPathComponent("tapq-opencode-hook")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip(
                "tapq-opencode-hook is not colocated with the test bundle; "
                    + "set TAPQ_OPENCODE_HOOK_EXECUTABLE to run this process contract"
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
private final class ApprovalRecorder {
    var requests: [ApprovalRequest] = []
}

@MainActor
private final class NotificationRecorder {
    var notifications: [AgentNotification] = []
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
