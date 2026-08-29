import Foundation
import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// A reasoner that answers from a script.
///
/// The whole loop is a conversation with a model, so every property worth pinning is a
/// property of "given these turns, what did TapQ do?" — which means the model has to be a
/// list. Each element is either the decision to return or the failure to throw, and the
/// requests it was given are kept so a test can assert on what crossed the boundary.
final class ScriptedTaskReasoner: WearerTaskReasoning, @unchecked Sendable {
    enum Turn {
        case decide(WearerTaskDecision)
        case fail(NarrationFailure)
    }

    private let lock = NSLock()
    private var script: [Turn]
    private var seen: [WearerTaskTurnRequest] = []
    /// What to do once the script runs dry. `finish` by default so a test that under-scripts
    /// ends with a clean sentence instead of an opaque hang.
    private let exhausted: Turn

    init(_ script: [Turn], whenExhausted: Turn = .decide(.finish(summary: "Done."))) {
        self.script = script
        self.exhausted = whenExhausted
    }

    var requests: [WearerTaskTurnRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var remaining: Int {
        lock.lock()
        defer { lock.unlock() }
        return script.count
    }

    func decide(_ request: WearerTaskTurnRequest) async throws -> WearerTaskDecision {
        lock.lock()
        seen.append(request)
        let turn = script.isEmpty ? exhausted : script.removeFirst()
        lock.unlock()
        switch turn {
        case .decide(let decision): return decision
        case .fail(let failure): throw failure
        }
    }
}

/// A reasoner that never answers, so a test can watch a task being cancelled mid-think.
final class HangingTaskReasoner: WearerTaskReasoning, @unchecked Sendable {
    func decide(_ request: WearerTaskTurnRequest) async throws -> WearerTaskDecision {
        // An hour, which is forever next to any test's patience. Cancellation unblocks it.
        try? await Task.sleep(for: .seconds(3_600))
        throw NarrationFailure.timedOut
    }
}

/// Everything the loop reached for, and everything it was told.
///
/// One object rather than seven closures at each call site: what a test asserts is usually a
/// *pair* — TapQ said this and queued that — and a recorder that holds both makes the
/// assertion read like the behavior.
@MainActor final class RecordingTaskSurfaces {
    var memoryAnswer: WearerTaskToolOutput = .ok("Nothing in memory.")
    var transcriptAnswer: WearerTaskToolOutput = .ok("Session history: the tests passed.")
    var statusAnswer: WearerTaskToolOutput = .ok("No agent can be addressed by name.")
    var queueAnswer: WearerTaskToolOutput = .ok("Queued.")
    var wearerAnswer: WearerTaskWearerAnswer = .yes

    private(set) var spoken: [String] = []
    private(set) var memoryQueries: [String] = []
    private(set) var transcriptQueries: [(agent: String?, query: String)] = []
    private(set) var statusCalls = 0
    private(set) var queued: [(agent: String?, text: String)] = []
    private(set) var asked: [String] = []
    private(set) var recorded: [(goal: String, outcome: String)] = []

    /// Fires as the last thing a task does, so an `async` test can await the background loop
    /// without polling a flag.
    var onRecorded: (@MainActor (String) -> Void)?

    func make() -> WearerTaskSurfaces {
        WearerTaskSurfaces(
            searchMemory: { [self] query in
                memoryQueries.append(query)
                return memoryAnswer
            },
            readTranscript: { [self] agent, query in
                transcriptQueries.append((agent, query))
                return transcriptAnswer
            },
            status: { [self] in
                statusCalls += 1
                return statusAnswer
            },
            queueInstruction: { [self] agent, text in
                queued.append((agent, text))
                return queueAnswer
            },
            speak: { [self] text in spoken.append(text) },
            askWearer: { [self] question in
                asked.append(question)
                return wearerAnswer
            },
            recordTask: { [self] goal, outcome in
                recorded.append((goal, outcome))
                onRecorded?(outcome)
            }
        )
    }
}

/// Collects diagnostics for the assertions that are about the log rather than the voice.
final class TaskDiagnosticSink: TapQDiagnosticSink, @unchecked Sendable {
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

    var names: [String] { events.map(\.name) }

    func first(_ name: String) -> TapQDiagnosticEvent? {
        events.first { $0.name == name }
    }

    func all(_ name: String) -> [TapQDiagnosticEvent] {
        events.filter { $0.name == name }
    }
}

extension XCTestCase {
    /// Waits for a background task lane to reach its ending.
    ///
    /// Polled rather than awaited on a continuation because the loop deliberately exposes no
    /// handle: `begin` returns the acknowledgment and the task runs off the voice turn, which
    /// is the behavior under test. One millisecond a turn, bounded, so a loop that never ends
    /// fails the test instead of hanging the suite.
    func awaitIdle(
        _ loop: WearerTaskLoop,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if await MainActor.run(body: { !loop.isBusy }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("the task never finished", file: file, line: line)
    }
}
