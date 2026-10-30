import Foundation
import TapQKernel
import TapQPOSIXSupport
import XCTest
@testable import TapQKernelCodex

final class CodexSessionCatalogTests: XCTestCase {
    private typealias F = CodexFixtures

    private let workspace = URL(fileURLWithPath: "/work/project")

    private static let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tapq","title":"TapQ","version":"1.2.3"},"capabilities":{"experimentalApi":false,"requestAttestation":false,"optOutNotificationMethods":["item/agentMessage/delta","item/commandExecution/outputDelta","item/fileChange/outputDelta","item/plan/delta","item/reasoning/summaryPartAdded","item/reasoning/summaryTextDelta","item/reasoning/textDelta","rawResponseItem/completed","turn/diff/updated"]}}}"#
    private static let threadList = #"{"id":2,"method":"thread/list","params":{"cwd":["/work/project"],"sourceKinds":["cli","vscode","appServer"],"sortKey":"updated_at","limit":50,"useStateDbOnly":true}}"#

    /// `v2/ThreadListResponse.json` of 0.161.0, trimmed to the members TapQ reads.
    private static let threads = #""result":{"data":["#
        + #"{"id":"019a-old","name":null,"preview":"run the tests","createdAt":1791600000,"updatedAt":1791700000,"parentThreadId":null,"source":"vscode"},"#
        + #"{"id":"019a-new","name":"Export feature","preview":"add an export button","createdAt":1791790000,"updatedAt":1791800000,"parentThreadId":null,"source":"cli"},"#
        + #"{"id":"019a-sub","name":null,"preview":"review the diff","createdAt":1791890000,"updatedAt":1791900000,"parentThreadId":"019a-new","source":"subAgent"},"#
        + #"{"id":"019a-blank","name":"  ","preview":"","createdAt":1791640000,"updatedAt":1791650000,"parentThreadId":null,"source":"cli"}"#
        + #"],"nextCursor":null}"#

    private func catalog(_ channel: ListingChannel, allowsUnsupportedVersion: Bool = false,
                         spawned: Locked<[CodexLaunchSpec]> = Locked([])) -> CodexSessionCatalog {
        CodexSessionCatalog(
            configuration: .init(executablePath: "/usr/local/bin/codex", clientVersion: "1.2.3",
                                 allowsUnsupportedVersion: allowsUnsupportedVersion),
            environment: ["PATH": "/usr/bin", "OPENAI_API_KEY": "sk-test", "TAPQ_OPENAI_API_KEY": "sk-tapq"],
            spawn: { spec in
                spawned.withValue { $0.append(spec) }
                return channel
            })
    }

    func testListsTheFoldersThreadsNewestFirstByNameElsePreviewWithoutSubagents() async throws {
        let channel = ListingChannel()
        channel.replies = ["initialize": F.initialize(), "thread/list": Self.threads]
        let spawned = Locked<[CodexLaunchSpec]>([])

        let sessions = try await catalog(channel, spawned: spawned).sessions(in: workspace)

        XCTAssertEqual(sessions, [
            SessionSummary(id: "019a-new", title: "Export feature", updatedAt: Date(timeIntervalSince1970: 1_791_800_000)),
            SessionSummary(id: "019a-old", title: "run the tests", updatedAt: Date(timeIntervalSince1970: 1_791_700_000)),
            SessionSummary(id: "019a-blank", title: "(conversation)", updatedAt: Date(timeIntervalSince1970: 1_791_650_000)),
        ])
        XCTAssertEqual(channel.written, [Self.initialize, #"{"method":"initialized"}"#, Self.threadList])
        XCTAssertTrue(channel.terminated, "the lister's own app-server is ended")
        let spec = try XCTUnwrap(spawned.withValue { $0.first })
        XCTAssertEqual(spec.workspace, workspace)
        XCTAssertEqual(spec.arguments, ["app-server"])
        XCTAssertNil(spec.environment["OPENAI_API_KEY"])
        XCTAssertNil(spec.environment["TAPQ_OPENAI_API_KEY"])
    }

    func testAFolderReachedThroughALinkIsListedUnderBothPaths() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-codex-catalog-\(UUID().uuidString)", isDirectory: true)
        let real = directory.appendingPathComponent("real", isDirectory: true)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let params = CodexSessionCatalog.listParams(link)
        XCTAssertTrue(params.hasPrefix(#"{"cwd":["\#(link.path)","\#(link.resolvingSymlinksInPath().path)"],"#), params)
    }

    func testAnUnsupportedVersionIsRefusedAndTheServerEnded() async throws {
        let channel = ListingChannel()
        channel.replies = ["initialize": F.initialize(version: "0.162.0"), "thread/list": Self.threads]
        do {
            _ = try await catalog(channel).sessions(in: workspace)
            XCTFail("listed with an unsupported Codex")
        } catch let error as CodexDelegateError {
            guard case .unsupportedVersion = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(channel.written.contains { $0.contains("thread/list") })
        XCTAssertTrue(channel.terminated)
    }

    func testTheDeveloperOverrideListsAnyVersion() async throws {
        let channel = ListingChannel()
        channel.replies = ["initialize": F.initialize(version: "0.162.0"), "thread/list": Self.threads]
        let sessions = try await catalog(channel, allowsUnsupportedVersion: true).sessions(in: workspace)
        XCTAssertEqual(sessions.count, 3)
    }

    func testARefusedListIsAnError() async throws {
        let channel = ListingChannel()
        channel.replies = ["initialize": F.initialize(),
                           "thread/list": #""error":{"code":-32600,"message":"state db unavailable"}"#]
        do {
            _ = try await catalog(channel).sessions(in: workspace)
            XCTFail("a refused list returned")
        } catch let error as CodexDelegateError {
            XCTAssertEqual(error, .rejected(method: "thread/list", message: "state db unavailable"))
        }
        XCTAssertTrue(channel.terminated)
    }

    func testAServerThatExitsBeforeAnsweringIsAnError() async throws {
        let channel = ListingChannel()
        channel.replies = ["initialize": F.initialize()]
        let catalog = catalog(channel)
        let listing = Task { try await catalog.sessions(in: workspace) }
        await waitFor { channel.written.contains(Self.threadList) }
        channel.feed(.exited(1))
        do {
            _ = try await listing.value
            XCTFail("listed from a server that exited")
        } catch let error as CodexDelegateError {
            XCTAssertEqual(error, .exited(1))
        }
    }

    /// The kernel's bound cancels a listing that takes too long: the server's stdin closes at
    /// once, and it is ended.
    func testACancelledListingEndsItsServer() async throws {
        let channel = ListingChannel()
        channel.replies = ["initialize": F.initialize()]
        let catalog = catalog(channel)
        let listing = Task { try await catalog.sessions(in: workspace) }
        await waitFor { channel.written.contains(Self.threadList) }
        listing.cancel()
        do {
            _ = try await listing.value
            XCTFail("a cancelled listing returned")
        } catch {}
        XCTAssertTrue(channel.inputClosed)
        XCTAssertTrue(channel.terminated)
    }

    private func waitFor(_ condition: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            await Task.yield()
        }
    }
}

/// A value shared with the catalog's tasks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// `FakeChannel` for a caller off the main actor: the catalog writes from its own task while
/// the test reads, so every member is behind a lock. Replies by method, like `FakeChannel`.
final class ListingChannel: LineChannel, @unchecked Sendable {
    private struct State {
        var replies: [String: String] = [:]
        var written: [String] = []
        var inputClosed = false
        var terminated = false
    }

    let signals: AsyncStream<ChannelSignal>
    private let continuation: AsyncStream<ChannelSignal>.Continuation
    private let state = Locked(State())

    init() {
        (signals, continuation) = AsyncStream<ChannelSignal>.makeStream()
    }

    var replies: [String: String] {
        get { state.withValue { $0.replies } }
        set { state.withValue { $0.replies = newValue } }
    }
    var written: [String] { state.withValue { $0.written } }
    var inputClosed: Bool { state.withValue { $0.inputClosed } }
    var terminated: Bool { state.withValue { $0.terminated } }

    func write(line: String) throws {
        let reply = state.withValue { state -> String? in
            state.written.append(line)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? Int, let method = object["method"] as? String,
                  let reply = state.replies[method] else { return nil }
            return "{\"id\":\(id),\(reply)}"
        }
        if let reply { continuation.yield(.stdout(reply)) }
    }

    func closeInput() { state.withValue { $0.inputClosed = true } }

    func terminate(grace: Duration, killAfter: Duration) async {
        state.withValue {
            $0.inputClosed = true
            $0.terminated = true
        }
        continuation.yield(.exited(0))
    }

    func feed(_ signal: ChannelSignal) { continuation.yield(signal) }
}
