import Foundation
import XCTest
import TapQContracts
import TapQKernel
import TapQPOSIXSupport
@testable import TapQKernelClaude

/// The delegate over a scripted `LineChannel`: start order, the lines it writes, and the
/// events it yields. Nothing here spawns a process.
@MainActor
final class ClaudeDelegateTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
    private let sessionUUID = UUID(uuidString: "2EF4A829-1045-4F5B-B7FE-38E4270D704E")!
    private let sessionID = "2ef4a829-1045-4f5b-b7fe-38e4270d704e"

    // MARK: - start

    /// 02-11: the session id is persisted before anything is spawned.
    func testStartPersistsTheSessionIDBeforeSpawning() async throws {
        var order: [String] = []
        let channel = ScriptedChannel()
        let delegate = makeDelegate { spec, environment in
            order.append("spawn")
            XCTAssertEqual(Array(spec.arguments.suffix(4)),
                           ["--session-id", "2ef4a829-1045-4f5b-b7fe-38e4270d704e",
                            "--setting-sources", "user,project,local"])
            XCTAssertNil(environment["OPENAI_API_KEY"])
            XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "anthropic-key")
            return channel
        }
        try await delegate.start(.fresh) { order.append("persist \($0)") }
        XCTAssertEqual(order, ["persist \(sessionID)", "spawn"])
    }

    func testAResumePassesTheIDToTheCLIAndToPersist() async throws {
        var persisted: String?
        var arguments: [String] = []
        let delegate = makeDelegate { spec, _ in
            arguments = spec.arguments
            return ScriptedChannel()
        }
        try await delegate.start(.resume(id: "abc")) { persisted = $0 }
        XCTAssertEqual(persisted, "abc")
        XCTAssertTrue(arguments.contains("--resume"))
        XCTAssertFalse(arguments.contains("--session-id"))
    }

    func testTheConfiguredModelIsOnTheCommandLine() async throws {
        var arguments: [String] = []
        let delegate = makeDelegate(model: "claude-haiku-5-5") { spec, _ in
            arguments = spec.arguments
            return ScriptedChannel()
        }
        try await delegate.start(.fresh) { _ in }
        XCTAssertEqual(arguments.firstIndex(of: "--model").map { arguments[$0 + 1] }, "claude-haiku-5-5")
    }

    func testAPersistThatThrowsAbortsStartBeforeAnySpawn() async {
        struct DiskFull: Error {}
        var spawned = false
        let delegate = makeDelegate { _, _ in
            spawned = true
            return ScriptedChannel()
        }
        do {
            try await delegate.start(.fresh) { _ in throw DiskFull() }
            XCTFail("start should have thrown")
        } catch {
            XCTAssertTrue(error is DiskFull)
        }
        XCTAssertFalse(spawned)
    }

    func testVerbsRefuseBeforeStartAndAfterStop() async throws {
        let delegate = makeDelegate { _, _ in ScriptedChannel() }
        XCTAssertThrowsError(try delegate.send("hi")) { error in
            XCTAssertEqual(error as? ClaudeDelegateError, .notStarted)
        }
        XCTAssertThrowsError(try delegate.resolve(permission: "r", .allow(always: false))) { error in
            XCTAssertEqual(error as? ClaudeDelegateError, .notStarted)
        }
        try await delegate.start(.fresh) { _ in }
        await delegate.stop()
        XCTAssertThrowsError(try delegate.interrupt()) { error in
            XCTAssertEqual(error as? ClaudeDelegateError, .stopped)
        }
    }

    // MARK: - Writing

    func testSendAndInterruptWriteTheirLines() async throws {
        let channel = ScriptedChannel()
        let delegate = makeDelegate { _, _ in channel }
        try await delegate.start(.fresh) { _ in }
        try delegate.send("run the tests")
        try delegate.interrupt()
        XCTAssertEqual(channel.written, [
            StreamJSONCodec.encodeUserMessage("run the tests"),
            ##"{"type":"control_request","request_id":"tapq-interrupt","request":{"subtype":"interrupt"}}"##,
        ])
    }

    func testAPermissionArrivesAndItsResolutionIsWritten() async throws {
        let channel = ScriptedChannel()
        let delegate = makeDelegate { _, _ in channel }
        let events = EventReader(delegate.events)
        try await delegate.start(.fresh) { _ in }
        channel.emit(.stdout(Fixtures.systemInit))
        channel.emit(.stdout(Fixtures.canUseToolBash))
        let received = try await events.read(until: { if case .permission = $0 { true } else { false } })
        guard case .permission(let request)? = received.last else { return XCTFail("\(received)") }
        try delegate.resolve(permission: request.id, .deny(feedback: "use pnpm"))
        XCTAssertEqual(channel.written.last,
                       ##"{"type":"control_response","response":{"subtype":"success","request_id":"602de92a-6878-4ce9-b730-d509f891207d","response":{"behavior":"deny","message":"use pnpm"}}}"##)
    }

    /// The kernel may decide on a request in the moment Claude Code withdraws it.
    func testResolvingAWithdrawnRequestWritesNothingAndDoesNotThrow() async throws {
        let channel = ScriptedChannel()
        let delegate = makeDelegate { _, _ in channel }
        let events = EventReader(delegate.events)
        try await delegate.start(.fresh) { _ in }
        channel.emit(.stdout(Fixtures.canUseToolBash))
        channel.emit(.stdout(ProtocolFrames.cancelBashRequest))
        _ = try await events.read(until: { $0 == .withdrawn(requestID: "602de92a-6878-4ce9-b730-d509f891207d") })
        try delegate.resolve(permission: "602de92a-6878-4ce9-b730-d509f891207d", .allow(always: false))
        XCTAssertEqual(channel.written, [])
    }

    func testControlRequestsTheLoopCannotServeAreAnsweredOnTheWire() async throws {
        let channel = ScriptedChannel()
        let delegate = makeDelegate { _, _ in channel }
        let events = EventReader(delegate.events)
        try await delegate.start(.fresh) { _ in }
        channel.emit(.stdout(ProtocolFrames.elicitation))
        channel.emit(.stdout(ProtocolFrames.hookCallback))
        channel.emit(.stdout(ProtocolFrames.requestUserDialog))
        channel.emit(.stdout(Fixtures.resultSuccess))
        _ = try await events.read(until: { $0 == .finished(text: "READY") })
        XCTAssertEqual(channel.written, [
            StreamJSONCodec.encodeElicitationDecline(requestID: "req-elicit"),
            StreamJSONCodec.encodeControlError(requestID: "req-hook", message: "TapQ does not handle hook_callback"),
        ])
    }

    /// D5's override reaches the first `system/init` check.
    func testAnUnsupportedSystemInitVersionIsAViolationUnlessOverridden() async throws {
        let initLine = ##"{"type":"system","subtype":"init","session_id":"\##(sessionID)","claude_code_version":"3.0.0"}"##
        for allowed in [false, true] {
            let channel = ScriptedChannel()
            let delegate = makeDelegate(allowsUnsupportedVersion: allowed) { _, _ in channel }
            let events = EventReader(delegate.events)
            try await delegate.start(.fresh) { _ in }
            channel.emit(.stdout(initLine))
            channel.emit(.stdout(Fixtures.resultSuccess))
            let received = try await events.read(until: { $0 == .finished(text: "READY") })
            XCTAssertEqual(Array(received.dropLast()), allowed ? [] : [
                .violation("Claude Code 3.0.0 is not supported. TapQ supports 2.1.260 through 2.1.293."),
            ])
        }
    }

    // MARK: - Exit and stop

    /// The stderr tail rides on `.exited`; the stream stays open for the kernel's fatal.
    func testAnExitTheKernelDidNotAskForCarriesTheStderrTail() async throws {
        let channel = ScriptedChannel()
        let delegate = makeDelegate { _, _ in channel }
        let events = EventReader(delegate.events)
        try await delegate.start(.fresh) { _ in }
        channel.emit(.stdout(ProtocolFrames.chatter))
        for index in 0..<25 { channel.emit(.stderr("line \(index)")) }
        channel.emit(.exited(1))
        let received = try await events.read(until: { if case .exited = $0 { true } else { false } })
        XCTAssertEqual(received, [.exited(code: 1, stderrTail: (5..<25).map { "line \($0)" })])
    }

    /// D13: stop terminates with 5 s then 2 s, finishes the stream, and reports no exit.
    func testStopTerminatesTheChannelAndEndsTheStreamWithoutAnExit() async throws {
        let channel = ScriptedChannel()
        let delegate = makeDelegate { _, _ in channel }
        let events = EventReader(delegate.events)
        try await delegate.start(.fresh) { _ in }
        await delegate.stop()
        XCTAssertEqual(channel.terminations, [ScriptedChannel.Termination(grace: .seconds(5), killAfter: .seconds(2))])
        let rest = try await events.readToEnd()
        XCTAssertEqual(rest, [])
    }

    // MARK: - Helpers

    private func makeDelegate(allowsUnsupportedVersion: Bool = false, model: String? = nil,
                              _ launch: @escaping ClaudeDelegate.Launch) -> ClaudeDelegate {
        let session = sessionUUID
        return ClaudeDelegate(configuration: .init(workspace: workspace, model: model,
                                                   executableOverride: "/usr/local/bin/claude",
                                                   checkedVersion: "2.1.283",
                                                   allowsUnsupportedVersion: allowsUnsupportedVersion),
                       environment: ["PATH": "/usr/bin", "OPENAI_API_KEY": "openai-key",
                                     "ANTHROPIC_API_KEY": "anthropic-key"],
                       launch: launch,
                       makeSessionID: { session },
                       makeRequestID: { "tapq-interrupt" })
    }
}

/// A `LineChannel` the test drives: it records what the delegate writes and emits what the
/// test says the child printed.
final class ScriptedChannel: LineChannel, @unchecked Sendable {
    struct Termination: Equatable {
        let grace: Duration
        let killAfter: Duration
    }

    let signals: AsyncStream<ChannelSignal>
    private let continuation: AsyncStream<ChannelSignal>.Continuation
    private let lock = NSLock()
    private var lines: [String] = []
    private var terminateCalls: [Termination] = []

    init() {
        let (stream, continuation) = AsyncStream<ChannelSignal>.makeStream()
        signals = stream
        self.continuation = continuation
    }

    var written: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    var terminations: [Termination] { lock.lock(); defer { lock.unlock() }; return terminateCalls }

    func write(line: String) throws {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func closeInput() {}

    func terminate(grace: Duration, killAfter: Duration) async {
        record(Termination(grace: grace, killAfter: killAfter))
        continuation.yield(.exited(0))
        continuation.finish()
    }

    private func record(_ termination: Termination) {
        lock.lock()
        defer { lock.unlock() }
        terminateCalls.append(termination)
    }

    func emit(_ signal: ChannelSignal) { continuation.yield(signal) }
}

private struct TimedOut: Error {}

/// One consumer of a stream across several bounded waits.
final class EventReader<Element: Sendable>: @unchecked Sendable {
    private var iterator: AsyncStream<Element>.AsyncIterator

    init(_ stream: AsyncStream<Element>) {
        iterator = stream.makeAsyncIterator()
    }

    /// Every element up to and including the first that satisfies `stop`.
    func read(until stop: @escaping @Sendable (Element) -> Bool,
              bound: Duration = .seconds(5)) async throws -> [Element] {
        try await bounded(bound) { reader in
            var received: [Element] = []
            while let element = await reader.iterator.next() {
                received.append(element)
                if stop(element) { return received }
            }
            throw TimedOut()
        }
    }

    /// Every element until the stream finishes.
    func readToEnd(bound: Duration = .seconds(5)) async throws -> [Element] {
        try await bounded(bound) { reader in
            var received: [Element] = []
            while let element = await reader.iterator.next() { received.append(element) }
            return received
        }
    }

    private func bounded(_ bound: Duration,
                         _ body: @escaping @Sendable (EventReader) async throws -> [Element]) async throws -> [Element] {
        try await withThrowingTaskGroup(of: [Element].self) { group in
            group.addTask { try await body(self) }
            group.addTask {
                try await Task.sleep(for: bound)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }
}
