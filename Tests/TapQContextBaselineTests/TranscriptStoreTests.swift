import Foundation
import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The transcript tail: what TapQ reads out of a file it does not own and cannot stop from
/// rewriting itself under it.
///
/// The fixtures are written here rather than checked in, deliberately: a `.jsonl` file in
/// the tree is refused by `scripts/check-public-boundary.sh`, and the interesting cases —
/// growth, truncation, a compaction that leaves the file *longer*, a half-written line —
/// are about a file changing between two reads, which a static fixture cannot express.
@MainActor
final class TranscriptStoreTests: XCTestCase {
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

        var names: [String] { events.map(\.name) }

        func fields(of name: String) -> [String: String]? {
            events.last { $0.name == name }?.fields
        }
    }

    private var directory: URL!
    private var path: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("session.jsonl").path
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func user(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"},"#
            + #""timestamp":"2026-08-29T10:00:00.000Z"}"#
    }

    private func assistant(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":"#
            + #"[{"type":"text","text":"\#(text)"}]},"#
            + #""timestamp":"2026-08-29T10:00:01.000Z"}"#
    }

    private func toolUse(_ name: String, _ command: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":"#
            + #"[{"type":"tool_use","name":"\#(name)","input":{"command":"\#(command)"}}]}}"#
    }

    private func toolResult(_ output: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"#
            + #"[{"type":"tool_result","content":"\#(output)"}]}}"#
    }

    private func write(_ lines: [String], newlineAtEnd: Bool = true) throws {
        var body = lines.joined(separator: "\n")
        if newlineAtEnd, !lines.isEmpty { body += "\n" }
        try Data(body.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func appendLine(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func texts(
        _ store: TranscriptStore,
        session: String = "s1",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String] {
        switch store.entries(session: session) {
        case .success(let entries):
            return entries.map(\.text)
        case .failure(let reason):
            XCTFail("transcript unavailable: \(reason.rawValue)", file: file, line: line)
            return []
        }
    }

    // MARK: - Growth

    /// The ordinary case: a file the agent keeps appending to, read from the byte after the
    /// last line TapQ already has.
    func testTailingReadsOnlyWhatIsNew() async throws {
        try write([user("start the migration"), assistant("running it now")])
        let store = TranscriptStore()
        store.attach(session: "s1", path: path)
        XCTAssertEqual(texts(store), ["start the migration", "running it now"])

        try appendLine(assistant("the migration finished"))
        XCTAssertEqual(texts(store),
                       ["start the migration", "running it now", "the migration finished"])
    }

    /// Attaching is called on every hook event. It must not re-read the file into a doubled
    /// tail, or the model would be shown the same turn several times over.
    func testAttachingTheSamePathAgainDoesNotDuplicateEntries() async throws {
        try write([user("hello")])
        let store = TranscriptStore()
        store.attach(session: "s1", path: path)
        store.attach(session: "s1", path: path)
        store.attach(session: "s1", path: path)

        XCTAssertEqual(texts(store), ["hello"])
    }

    /// A read can land in the middle of a line the agent is still writing. Those bytes are
    /// left unconsumed so the line is parsed once, whole, on the next read — rather than
    /// counted as a permanent parse failure.
    func testAHalfWrittenLineIsParsedOnlyOnceItIsWhole() async throws {
        try write([user("first")], newlineAtEnd: true)
        let store = TranscriptStore()
        store.attach(session: "s1", path: path)
        XCTAssertEqual(texts(store), ["first"])

        // The agent starts writing a second line and stops mid-flight.
        let partial = String(assistant("second").prefix(30))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(partial.utf8))
        try handle.close()
        XCTAssertEqual(texts(store), ["first"], "a partial line must not be parsed")

        // …and then finishes it.
        let rest = String(assistant("second").dropFirst(30))
        let second = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try second.seekToEnd()
        try second.write(contentsOf: Data((rest + "\n").utf8))
        try second.close()
        XCTAssertEqual(texts(store), ["first", "second"])
    }

    // MARK: - The file rewriting itself

    /// Compaction that leaves the file *shorter*. The offset now points past the end, so
    /// everything held is about a conversation that no longer exists.
    func testTruncationResyncsFromTheTop() async throws {
        try write([user("one"), assistant("two"), assistant("three")])
        let sink = RecordingSink()
        let store = TranscriptStore(diagnosticSink: sink)
        store.attach(session: "s1", path: path)
        XCTAssertEqual(texts(store).count, 3)

        try write([user("compacted summary")])

        XCTAssertEqual(texts(store), ["compacted summary"])
        XCTAssertTrue(sink.names.contains("transcript.resynced"), "\(sink.names)")
        XCTAssertEqual(sink.fields(of: "transcript.resynced")?["reason"], "truncated")
    }

    /// The harder rewrite: the new file is *longer* than the old offset, so a size check
    /// alone says "nothing to do but read from here" — and reading from there would splice
    /// the middle of one line onto the tail of a conversation that is gone. The offset is
    /// therefore also checked for sitting immediately after a newline.
    func testARewriteThatLeavesTheFileLongerAlsoResyncs() async throws {
        try write([user("one"), user("two")])
        let sink = RecordingSink()
        let store = TranscriptStore(diagnosticSink: sink)
        store.attach(session: "s1", path: path)
        XCTAssertEqual(texts(store).count, 2)

        // One line, no newlines inside it, longer than the two it replaces — so the old
        // offset lands in the middle of it.
        try write([user(String(repeating: "x", count: 4_000))])

        let entries = texts(store)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.count, 4_000)
        XCTAssertEqual(sink.fields(of: "transcript.resynced")?["reason"], "offset_invalid")
    }

    /// A session TapQ meets for the first time with megabytes already in it: the read starts
    /// at the last window rather than parsing the whole history at a turn boundary.
    func testAFileFarLargerThanTheWindowIsReadFromItsTail() async throws {
        let filler = (0..<200).map { user("line \($0) " + String(repeating: "y", count: 200)) }
        try write(filler + [assistant("the last thing that happened")])
        let sink = RecordingSink()
        let store = TranscriptStore(readWindowBytes: 4_096, diagnosticSink: sink)
        store.attach(session: "s1", path: path)

        let entries = texts(store)
        XCTAssertEqual(entries.last, "the last thing that happened")
        XCTAssertLessThan(entries.count, 200, "the whole history must not be parsed")
        XCTAssertEqual(sink.fields(of: "transcript.resynced")?["reason"], "window_clamped")
    }

    /// A session that moved to a different file is a different conversation: the offset and
    /// the tail from the old one mean nothing.
    func testReattachingADifferentPathResetsTheTail() async throws {
        try write([user("old conversation")])
        let store = TranscriptStore()
        store.attach(session: "s1", path: path)
        XCTAssertEqual(texts(store), ["old conversation"])

        let other = directory.appendingPathComponent("other.jsonl")
        try Data((user("new conversation") + "\n").utf8).write(to: other)
        store.attach(session: "s1", path: other.path)

        XCTAssertEqual(texts(store), ["new conversation"])
    }

    // MARK: - Malformed input

    /// Junk between good lines costs those lines and nothing else. The count is reported;
    /// the content never is.
    func testMalformedLinesAreSkippedAndCountedWithoutTheirContent() async throws {
        let sink = RecordingSink()
        try write([
            user("good one"),
            "{ not json at all",
            "",
            #"{"type":"assistant"}"#,          // no content anywhere: carries no history
            assistant("good two"),
        ])
        let store = TranscriptStore(diagnosticSink: sink)
        store.attach(session: "s1", path: path)

        XCTAssertEqual(texts(store), ["good one", "good two"])
        let tailed = try XCTUnwrap(sink.fields(of: "transcript.tailed"))
        // Two lines produced no entry: the one that is not JSON, and the one that is JSON
        // but carries no prose, no tool, and no output. An empty line is not counted — it
        // is not a line anything was lost from.
        XCTAssertEqual(tailed["malformed"], "2")
        for event in sink.events {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("good one"),
                               "a diagnostic carried transcript content")
            }
        }
    }

    // MARK: - Unavailability

    /// Three different ways to have no transcript, kept apart because the wearer hears a
    /// different sentence for the first and the operator reads a different reason for all
    /// three.
    func testTheThreeUnavailableReasonsAreDistinct() async throws {
        let store = TranscriptStore()
        guard case .failure(.notAttached) = store.entries(session: "unknown") else {
            return XCTFail("an unknown session must report notAttached")
        }

        store.attach(session: "gone", path: directory.appendingPathComponent("no.jsonl").path)
        guard case .failure(.unreadable) = store.entries(session: "gone") else {
            return XCTFail("a missing file must report unreadable")
        }

        try write(["{ junk", "also junk"])
        store.attach(session: "s1", path: path)
        guard case .failure(.empty) = store.entries(session: "s1") else {
            return XCTFail("a file with nothing legible must report empty")
        }
    }

    /// An unreadable transcript is an *error*-level fact, because the wearer is about to be
    /// told out loud that TapQ cannot see the session — but it is not a break, and nothing
    /// here throws.
    func testAnUnreadableTranscriptIsRecordedAtErrorLevel() async throws {
        let sink = RecordingSink()
        let store = TranscriptStore(diagnosticSink: sink)
        store.attach(session: "s1", path: directory.appendingPathComponent("no.jsonl").path)
        _ = store.entries(session: "s1")

        let event = try XCTUnwrap(sink.events.last { $0.name == "transcript.unavailable" })
        XCTAssertEqual(event.level, .error)
        XCTAssertEqual(event.fields["reason"], "unreadable")
    }

    // MARK: - Parsing

    /// A tool call and its result are the two halves a question like "what did the tests
    /// say?" is answered from, so both are parsed into their own fields rather than flattened
    /// into prose.
    func testToolUseAndToolResultKeepTheirParts() async throws {
        try write([toolUse("Bash", "swift test"), toolResult("Executed 12 tests, 0 failures")])
        let store = TranscriptStore()
        store.attach(session: "s1", path: path)
        guard case .success(let entries) = store.entries(session: "s1") else {
            return XCTFail("expected entries")
        }

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].role, .assistant)
        XCTAssertEqual(entries[0].toolName, "Bash")
        XCTAssertEqual(entries[0].toolInput, #"{"command":"swift test"}"#)
        XCTAssertEqual(entries[1].role, .toolResult)
        XCTAssertEqual(entries[1].toolOutput, "Executed 12 tests, 0 failures")
        XCTAssertTrue(entries[1].rendered.contains("Executed 12 tests, 0 failures"))
    }

    func testTimestampsAreParsedWhenPresent() async throws {
        try write([user("hello")])
        let store = TranscriptStore()
        store.attach(session: "s1", path: path)
        guard case .success(let entries) = store.entries(session: "s1") else {
            return XCTFail("expected entries")
        }
        XCTAssertNotNil(entries.first?.timestamp)
    }

    /// The tail is bounded. A session that runs all day must not turn into a heap the
    /// runtime carries around.
    func testTheInMemoryTailIsBounded() async throws {
        try write((0..<50).map { user("line \($0)") })
        let store = TranscriptStore(tailEntryLimit: 10)
        store.attach(session: "s1", path: path)

        let entries = texts(store)
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.last, "line 49", "the newest entries are the ones kept")
    }

    /// The other half of the bounded tail: history older than it is still reachable, because
    /// the agent's own file is the store and TapQ kept no copy to lose.
    func testRereadingReachesPastTheBoundedTailWithoutDisturbingIt() async throws {
        try write((0..<50).map { user("line \($0)") })
        let store = TranscriptStore(tailEntryLimit: 10)
        store.attach(session: "s1", path: path)
        XCTAssertEqual(texts(store).count, 10)

        guard case .success(let all) = store.reread(session: "s1") else {
            return XCTFail("a re-read of a readable file must succeed")
        }
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(all.first?.text, "line 0")
        XCTAssertEqual(texts(store).count, 10,
                       "a re-read must leave the checkpoint and the tail alone")
        XCTAssertEqual(store.tailLimit, 10)
    }

    /// Nothing about a transcript is written down: the store holds an offset and a tail, and
    /// the only file involved is the agent's own.
    func testTheStoreWritesNothingToDisk() async throws {
        try write([user("hello")])
        let store = TranscriptStore()
        store.attach(session: "s1", path: path)
        _ = texts(store)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["session.jsonl"])
    }

    /// With one agent connected there is no ambiguity about which session a question is
    /// about, and that is the resolution M1 ships.
    func testTheMostRecentlyActiveSessionIsTheOneAnswered() async throws {
        try write([user("first session")])
        let other = directory.appendingPathComponent("other.jsonl")
        try Data((user("second session") + "\n").utf8).write(to: other)

        let store = TranscriptStore()
        store.attach(session: "s1", path: path)
        store.attach(session: "s2", path: other.path)
        _ = store.entries(session: "s2")

        XCTAssertEqual(store.mostRecentlyActiveSession(), "s2")
        XCTAssertEqual(store.attachedSessions, ["s1", "s2"])
    }
}
