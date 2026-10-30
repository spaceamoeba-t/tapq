import Foundation
import TapQKernel
import TapQPOSIXSupport
import XCTest
@testable import TapQKernelCodex

/// A scripted `codex app-server`. It records every line TapQ writes and, when `replies`
/// holds an answer for the method just written, feeds the response back at once, so the
/// handshake runs without a clock. Used on the main actor only.
final class FakeChannel: LineChannel, @unchecked Sendable {
    let signals: AsyncStream<ChannelSignal>
    private let continuation: AsyncStream<ChannelSignal>.Continuation

    /// method → the members after `"id":n,`, e.g. `"result":{}`.
    var replies: [String: String] = [:]
    private(set) var written: [String] = []
    private(set) var inputClosed = false
    private(set) var terminated: (grace: Duration, killAfter: Duration)?

    init() {
        (signals, continuation) = AsyncStream<ChannelSignal>.makeStream()
    }

    func write(line: String) throws {
        written.append(line)
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String,
              let reply = replies[method] else { return }
        feed("{\"id\":\(id),\(reply)}")
    }

    func closeInput() {
        inputClosed = true
    }

    /// Like `ChildProcess`: stdin closes first, and the exit follows.
    func terminate(grace: Duration, killAfter: Duration) async {
        closeInput()
        terminated = (grace, killAfter)
        continuation.yield(.exited(0))
    }

    func feed(_ line: String) {
        continuation.yield(.stdout(line))
    }

    func feed(_ signal: ChannelSignal) {
        continuation.yield(signal)
    }
}

/// Every event the delegate emits, in order.
@MainActor
final class EventRecorder {
    private(set) var events: [DelegateEvent] = []

    init(_ stream: AsyncStream<DelegateEvent>) {
        Task { [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }
}

/// A bounded wait on the condition a test asserts; never a fixed sleep or yield count.
@MainActor
func eventually(_ condition: () -> Bool, timeout: Duration = .seconds(5),
                file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            return XCTFail("timed out waiting for the condition", file: file, line: line)
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
