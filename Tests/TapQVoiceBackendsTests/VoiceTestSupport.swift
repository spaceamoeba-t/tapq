import XCTest
import Foundation
import TapQContracts

/// Waits for `condition`, bounded: the event a test asserts, never a count of hops.
@MainActor
func waitUntil(_ condition: () -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { return XCTFail("timed out waiting", file: file, line: line) }
        await Task.yield()
    }
}

/// Everything a stream delivered, and whether it finished.
@MainActor
final class StreamLog<Event: Sendable> {
    private(set) var events: [Event] = []
    private(set) var finished = false

    init(_ stream: AsyncStream<Event>) {
        Task { @MainActor in
            for await event in stream { self.events.append(event) }
            self.finished = true
        }
    }
}

/// A `sleep` the test releases by hand, so a call bound fires when the test says so and
/// never because a clock ran.
final class ManualSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []

    var sleep: @Sendable (TimeInterval) async -> Void {
        { [self] _ in await withCheckedContinuation { park($0) } }
    }

    /// Wakes every sleeper parked now. A woken bound that was cancelled meanwhile does
    /// nothing, as a real one would.
    func fireAll() {
        lock.lock()
        let woken = parked
        parked = []
        lock.unlock()
        woken.forEach { $0.resume() }
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        parked.append(continuation)
        lock.unlock()
    }
}

final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
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

    func first(_ name: String) -> TapQDiagnosticEvent? { events.first { $0.name == name } }
}

/// PCM16 mono 24 kHz: `seconds` of `byte`, stamped `at`.
func pcm(at timestamp: TimeInterval, seconds: TimeInterval = 0.1,
         byte: UInt8 = 0x11) -> VoiceAudioChunk {
    VoiceAudioChunk(data: Data(repeating: byte, count: Int((seconds * 24_000).rounded()) * 2),
                    format: .pcm16Mono24k, timestamp: timestamp)
}
