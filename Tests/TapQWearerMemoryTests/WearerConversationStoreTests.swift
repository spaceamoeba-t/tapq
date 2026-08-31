import Foundation
import XCTest
import TapQContracts
@testable import TapQContextBaseline

/// A clock a test can move.
///
/// A class with a lock rather than a captured `var`, because the store takes a
/// `@Sendable` closure and a mutable capture would be a data race the compiler is right
/// to complain about — and because a rotation test has to be able to jump a month
/// forward between two appends.
final class SteppableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) {
        now = start
    }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        now = now.addingTimeInterval(interval)
        lock.unlock()
    }

    var read: @Sendable () -> Date {
        { self.date }
    }
}

/// TapQ's own durable memory of what it and the wearer have said to each other
/// (`WearerConversationStore`, Pillar A of docs/TAPQ_AGENT_PLAN.md, milestone M1).
///
/// The properties under test are the ones the plan makes promises about: it survives a
/// restart, it bounds itself by age and by size without losing the newest thing said, a
/// torn line does not cost the wearer their month, and `tapq memory clear` empties it.
final class WearerConversationStoreTests: XCTestCase {
    private var directory: URL!
    /// A fixed, far-from-epoch instant so a 30-day subtraction stays a real date.
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-wearer-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Append and read back

    @MainActor
    func testEveryRecordedKindReadsBackWithItsFields() async {
        let store = makeStore()
        store.recordWearerUtterance("run the tests when you're done")
        store.recordSpokenSentence("Claude Code wants to run npm test.")
        store.recordDecision(
            agentDisplayName: "Claude Code",
            summary: "swift test",
            outcome: "approved",
            toolName: "Bash"
        )
        store.recordInstruction(agentDisplayName: "Codex", text: "rerun the failing suite")

        let entries = store.entries()
        XCTAssertEqual(entries.map(\.kind), [
            .wearerSaid, .tapqSaid, .decision, .instruction,
        ])
        XCTAssertEqual(entries[0].text, "run the tests when you're done")
        XCTAssertEqual(entries[1].text, "Claude Code wants to run npm test.")
        XCTAssertEqual(entries[2].outcome, "approved")
        XCTAssertEqual(entries[2].toolName, "Bash")
        XCTAssertEqual(entries[2].agentDisplayName, "Claude Code")
        XCTAssertEqual(entries[3].text, "rerun the failing suite")
        XCTAssertEqual(entries[3].agentDisplayName, "Codex")
    }

    /// The M3 addition, made exactly the way this type's doc comment predicted one would be:
    /// one `static let` and one recorder.
    ///
    /// The lifecycle is several entries rather than the task record's pair, and that is what
    /// makes the bound honest: a follow-up lives only in memory, so this file is the only
    /// place one that expired with the runtime leaves any trace at all.
    @MainActor
    func testAFollowupsWholeLifecycleReadsBackFromTheRecord() async {
        let store = makeStore()
        store.recordFollowup(agentDisplayName: "Claude Code",
                             instruction: "rerun the tests",
                             event: WearerFollowupEvent.created)
        store.recordFollowup(agentDisplayName: "Claude Code",
                             instruction: "just tell me what broke",
                             event: WearerFollowupEvent.replaced)
        store.recordFollowup(agentDisplayName: "Claude Code",
                             instruction: "just tell me what broke",
                             event: WearerFollowupEvent.fired(.finished))

        let entries = store.entries()
        XCTAssertEqual(entries.map(\.kind), [.followup, .followup, .followup])
        XCTAssertEqual(entries.map(\.outcome), ["created", "replaced", "fired: finished"])
        XCTAssertEqual(entries.last?.text, "just tell me what broke")
        XCTAssertEqual(entries.last?.agentDisplayName, "Claude Code")
        // The open rawValue is what makes this addition free: the on-disk word is the kind,
        // and an older build renders an unrecognized one as itself rather than failing the
        // line and taking the wearer's month with it.
        XCTAssertEqual(WearerDialogueKind.followup.rawValue, "followup")
    }

    /// Nothing goes in with no words in it. A recognizer that finalized silence would
    /// otherwise fill the window with blank turns and push the real history out of it.
    @MainActor
    func testEmptyUtterancesAreNotRecorded() async {
        let store = makeStore()
        store.recordWearerUtterance("   ")
        store.recordSpokenSentence("")
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// Whitespace is collapsed and a runaway recognizer is capped. Verbatim means "not
    /// summarized", not "unbounded": the cap exists so a microphone that ran away with a
    /// nearby conversation cannot turn one utterance into a page of prompt.
    @MainActor
    func testTextIsNormalizedAndCapped() async {
        let store = makeStore()
        store.recordWearerUtterance("run   the\n tests")
        store.recordWearerUtterance(String(repeating: "a", count: 900))

        let entries = store.entries()
        XCTAssertEqual(entries[0].text, "run the tests")
        XCTAssertEqual(entries[1].text.count, WearerDialogueEntry.textCharacterLimit)
    }

    // MARK: - Durability

    /// The restart. A second store over the same directory is a new process reading the
    /// file the old one left, which is what "survives realtime-session recycling and
    /// runtime restarts" has to mean in a test.
    @MainActor
    func testTheRecordSurvivesAStoreReopen() async {
        let first = makeStore()
        first.recordWearerUtterance("remind me what Codex was doing")
        first.recordSpokenSentence("Codex is waiting on the migration.")

        let second = makeStore()
        XCTAssertEqual(second.entries().map(\.text), [
            "remind me what Codex was doing",
            "Codex is waiting on the migration.",
        ])
        XCTAssertEqual(second.entries().map(\.kind), [.wearerSaid, .tapqSaid])
        XCTAssertEqual(second.entries()[0].timestamp, start)
    }

    /// The file is `0600`, like every other artifact in the runtime's `0700` directory.
    @MainActor
    func testTheFileIsPrivateToTheUser() async throws {
        let store = makeStore()
        store.recordWearerUtterance("anything")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// A kind this build has never heard of — an M3 standing directive read by an M1
    /// binary — round-trips instead of failing the line. This is the whole of the
    /// "no migration for M3" claim, and the reason `WearerDialogueKind` is an open
    /// rawValue rather than an `enum`.
    @MainActor
    func testAnUnknownEntryKindSurvivesAReopen() async throws {
        let line = #"{"agent":"","kind":"directive","outcome":"","tool":"","ts":"2027-01-01T00:00:00.000Z","text":"watch the build and tell me if it fails"}"#
        try Data((line + "\n").utf8).write(
            to: directory.appendingPathComponent(WearerConversationStore.fileName))

        let store = makeStore()
        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind.rawValue, "directive")
        XCTAssertEqual(entries[0].text, "watch the build and tell me if it fails")

        // And it is still there after this build appends to the same file.
        store.recordWearerUtterance("what are you watching?")
        XCTAssertEqual(makeStore().entries().count, 2)
    }

    /// One unreadable line — a torn tail after a crash — costs that line and nothing else.
    @MainActor
    func testATornLineIsSkippedRatherThanLosingTheRecord() async throws {
        let good = #"{"agent":"","kind":"wearer_said","outcome":"","tool":"","ts":"2027-01-01T00:00:00.000Z","text":"the first thing"}"#
        let torn = #"{"agent":"","kind":"wearer_sa"#
        try Data((good + "\n" + torn).utf8).write(
            to: directory.appendingPathComponent(WearerConversationStore.fileName))

        let store = makeStore()
        XCTAssertEqual(store.entries().map(\.text), ["the first thing"])
        // The rewrite that drops it is the only way a bad line ever leaves the file.
        XCTAssertEqual(makeStore().entries().map(\.text), ["the first thing"])
    }

    // MARK: - Rotation

    /// 30 days, ratified 2026-08-29. The append that crosses the boundary is what prunes.
    @MainActor
    func testEntriesOlderThanRetentionAreDroppedOnAppend() async {
        let clock = SteppableClock(start)
        let store = makeStore(clock: clock)
        store.recordWearerUtterance("a month ago")

        clock.advance(by: WearerConversationStore.defaultRetention + 60)
        store.recordWearerUtterance("just now")

        XCTAssertEqual(store.entries().map(\.text), ["just now"])
        // And the file agrees: rotation rewrites rather than only forgetting in memory.
        XCTAssertEqual(makeStore(clock: clock).entries().map(\.text), ["just now"])
    }

    /// A runtime coming back after a fortnight away starts with the file already pruned,
    /// rather than pruning it at the first thing the wearer says.
    @MainActor
    func testExpiredEntriesAreDroppedWhenTheStoreReopens() async {
        let clock = SteppableClock(start)
        let first = makeStore(clock: clock)
        first.recordWearerUtterance("long ago")
        clock.advance(by: 10)
        first.recordWearerUtterance("also long ago")

        clock.advance(by: WearerConversationStore.defaultRetention + 60)
        XCTAssertTrue(makeStore(clock: clock).entries().isEmpty)
    }

    /// The boundary is not a rounding error: an entry exactly at the cutoff is inside the
    /// window, and only what is strictly older goes.
    @MainActor
    func testAnEntryOnTheRetentionBoundaryIsKept() async {
        let clock = SteppableClock(start)
        let store = makeStore(clock: clock)
        store.recordWearerUtterance("oldest")
        clock.advance(by: 10)
        store.recordWearerUtterance("ten seconds later")

        // Now is exactly one retention period past the second entry.
        clock.advance(by: WearerConversationStore.defaultRetention)
        XCTAssertEqual(
            makeStore(clock: clock).entries().map(\.text),
            ["ten seconds later"]
        )
    }

    /// The size cap binds when it binds first, and it binds by dropping the *oldest*: a
    /// rotation that emptied the live file would erase the wearer's recent history at the
    /// exact moment it got interesting, which is why this compacts in place rather than
    /// moving a generation aside the way the review logs do.
    @MainActor
    func testTheSizeCapDropsTheOldestAndKeepsTheNewest() async {
        let cap = 1_200
        let store = makeStore(maximumBytes: cap)
        for index in 1...40 {
            store.recordWearerUtterance("utterance number \(index)")
        }

        XCTAssertLessThanOrEqual(store.storedByteCount, cap)
        let texts = store.entries().map(\.text)
        XCTAssertEqual(texts.last, "utterance number 40")
        XCTAssertFalse(texts.contains("utterance number 1"))
        XCTAssertGreaterThan(texts.count, 1)

        // The bytes on disk are the bytes the store thinks it has.
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes?[.size] as? NSNumber)?.intValue, store.storedByteCount)
        XCTAssertEqual(makeStore(maximumBytes: cap).entries().map(\.text), texts)
    }

    /// Compaction goes *past* the cap, not to it, so the append right after a rotation
    /// does not rotate again. Asserted at the moment the first rotation lands, because
    /// that is the only moment the property is about: after it, ordinary appends climb
    /// back towards the cap, which is what the headroom is for.
    @MainActor
    func testCompactionLeavesHeadroomBelowTheCap() async {
        let cap = 1_200
        let target = Int(Double(cap) * WearerConversationStore.compactionFraction)
        let sink = RotationCounter()
        let store = makeStore(maximumBytes: cap, sink: sink)

        var rotated = false
        for index in 1...200 where !rotated {
            store.recordWearerUtterance("utterance number \(index)")
            guard sink.rotations > 0 else { continue }
            rotated = true
            XCTAssertLessThanOrEqual(store.storedByteCount, target)
        }
        XCTAssertTrue(rotated, "the cap was never reached")
    }

    // MARK: - Clearing

    @MainActor
    func testClearRemovesTheFileAndEverythingHeld() async {
        let store = makeStore()
        store.recordWearerUtterance("something private")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        XCTAssertTrue(store.clear())
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertEqual(store.storedByteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(makeStore().entries().isEmpty)
    }

    /// Clearing what is not there is not an error; it is a different sentence.
    @MainActor
    func testClearReportsThatThereWasNothingToRemove() async {
        XCTAssertFalse(makeStore().clear())
    }

    /// A cleared store is a working store: the next thing said starts the file again.
    @MainActor
    func testTheStoreKeepsRecordingAfterAClear() async {
        let store = makeStore()
        store.recordWearerUtterance("before")
        store.clear()
        store.recordWearerUtterance("after")
        XCTAssertEqual(makeStore().entries().map(\.text), ["after"])
    }

    // MARK: - The recent window

    @MainActor
    func testTheRecentWindowIsBoundedByCount() async {
        let store = makeStore()
        for index in 1...(WearerConversationRecall.windowEntryLimit + 6) {
            store.recordWearerUtterance("line \(index)")
        }
        let window = store.recentWindow()
        XCTAssertEqual(window.count, WearerConversationRecall.windowEntryLimit)
        XCTAssertEqual(window.last?.text, "line \(WearerConversationRecall.windowEntryLimit + 6)")
        XCTAssertEqual(window.first?.text, "line 7")
    }

    /// The character budget is spent from the newest end backwards, so what survives a
    /// tight budget is always the most recent thing said — the entries the wearer is most
    /// likely to mean by "earlier".
    @MainActor
    func testTheRecentWindowSpendsItsCharacterBudgetOnTheNewest() async {
        let store = makeStore()
        for index in 1...8 {
            store.recordWearerUtterance("line \(index)")
        }
        let window = store.recentWindow(characterBudget: 30)
        XCTAssertFalse(window.isEmpty)
        XCTAssertEqual(window.last?.text, "line 8")
        XCTAssertFalse(window.map(\.text).contains("line 1"))
    }

    @MainActor
    func testTheRecentWindowIsOldestFirst() async {
        let store = makeStore()
        store.recordWearerUtterance("first")
        store.recordWearerUtterance("second")
        XCTAssertEqual(store.recentWindow().map(\.text), ["first", "second"])
    }

    // MARK: - Helpers

    /// Counts the store's own `rotated` diagnostic, which is the only way to observe the
    /// moment a rotation lands rather than guessing at it from the byte count.
    private final class RotationCounter: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record(_ event: TapQDiagnosticEvent) {
            guard event.name == "rotated" else { return }
            lock.lock()
            count += 1
            lock.unlock()
        }

        var rotations: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @MainActor
    private func makeStore(
        clock: SteppableClock? = nil,
        maximumBytes: Int = WearerConversationStore.defaultMaximumBytes,
        sink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) -> WearerConversationStore {
        let start = start
        return WearerConversationStore(
            directory: directory,
            clock: clock?.read ?? { start },
            maximumBytes: maximumBytes,
            diagnosticSink: sink
        )
    }
}
