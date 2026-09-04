import Foundation
import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The session book (`docs/SESSION_FOCUS_PLAN.md` §4): what a restart reads to know which
/// sessions are detached, and what "go back" would read later to know where a session was.
@MainActor
final class SessionBookTests: XCTestCase {
    /// The injected clock, in a box the book's `@Sendable` closure may capture.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = Date(timeIntervalSince1970: 1_700_000_000)

        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return instant }
            set { lock.lock(); instant = newValue; lock.unlock() }
        }
    }

    private var directory: URL!
    private let clock = Clock()
    private var now: Date {
        get { clock.now }
        set { clock.now = newValue }
    }

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-session-book-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = self.directory!
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeBook() -> SessionBook {
        let clock = self.clock
        return SessionBook(directory: directory, clock: { clock.now })
    }

    func testASessionsLifeFoldsIntoOneRecord() async {
        let book = makeBook()
        book.recordStarted(sessionID: "owned-1", agent: .claudeCode,
                           workingDirectory: "/Users/me/repo", goal: "fix the login bug",
                           ownedByTapQ: true)
        XCTAssertEqual(book.focusedSession(agentID: "claude-code")?.sessionID, "owned-1")

        now = now.addingTimeInterval(60)
        book.recordDetached(sessionID: "owned-1", agent: .claudeCode,
                            ending: WearerSessionEvent.detachedAndStopped)
        XCTAssertNil(book.focusedSession(agentID: "claude-code"))
        XCTAssertEqual(book.detachedSessions(agentID: "claude-code").map(\.sessionID),
                       ["owned-1"])

        now = now.addingTimeInterval(60)
        book.recordEnded(sessionID: "owned-1", agent: .claudeCode, ending: "detached: stopped")

        let record = book.record(sessionID: "OWNED-1")
        XCTAssertEqual(record?.goal, "fix the login bug")
        XCTAssertEqual(record?.workingDirectory, "/Users/me/repo")
        XCTAssertEqual(record?.ownedByTapQ, true)
        XCTAssertNotNil(record?.detachedAt)
        XCTAssertNotNil(record?.endedAt)
        XCTAssertEqual(record?.ending, "detached: stopped")
        XCTAssertTrue(book.detachedSessions(agentID: "claude-code").isEmpty,
                      "an ended session is no longer detached")
    }

    /// A keyboard session's directory arrives later, from a hook that carried it, and is
    /// written once.
    func testAWorkingDirectoryLearnedLaterIsRecordedOnce() async {
        let book = makeBook()
        book.recordStarted(sessionID: "kb-1", agent: .claudeCode)
        XCTAssertNil(book.workingDirectory(sessionID: "kb-1"))

        book.noteWorkingDirectory(sessionID: "kb-1", agent: .claudeCode, path: "/Users/me/a")
        book.noteWorkingDirectory(sessionID: "kb-1", agent: .claudeCode, path: "/Users/me/b")

        XCTAssertEqual(book.workingDirectory(sessionID: "kb-1"), "/Users/me/a")
        XCTAssertEqual(book.eventCount, 2)
    }

    /// The restart case. Everything survives a reopen, and the detached set is what the
    /// roster is told before any hook arrives.
    func testTheBookSurvivesAReopen() async throws {
        let book = makeBook()
        book.recordStarted(sessionID: "kb-1", agent: .claudeCode, workingDirectory: "/r")
        book.recordDetached(sessionID: "kb-1", agent: .claudeCode,
                            ending: WearerSessionEvent.detachedToKeyboard)
        book.recordStarted(sessionID: "owned-2", agent: .claudeCode, goal: "run the tests",
                           ownedByTapQ: true)

        let reopened = makeBook()
        XCTAssertEqual(reopened.eventCount, 3)
        XCTAssertEqual(reopened.detachedSessions(agentID: "claude-code").map(\.sessionID),
                       ["kb-1"])
        XCTAssertEqual(reopened.focusedSession(agentID: "claude-code")?.sessionID, "owned-2")
        XCTAssertEqual(reopened.workingDirectory(sessionID: "kb-1"), "/r")

        let attributes = try FileManager.default.attributesOfItem(atPath: book.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    func testATornLineIsSkippedRatherThanLosingTheBook() async throws {
        let book = makeBook()
        book.recordStarted(sessionID: "kb-1", agent: .claudeCode)
        let handle = try FileHandle(forWritingTo: book.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"ts\":\"20".utf8))
        try handle.close()

        let reopened = makeBook()
        XCTAssertEqual(reopened.records().map(\.sessionID), ["kb-1"])
    }

    /// Bounded by count: past the cap the events of ended sessions go first, and a session
    /// still on the books keeps its events.
    func testTheBoundDropsEndedSessionsFirst() async {
        let book = makeBook()
        for index in 0..<(SessionBook.maximumEvents / 2) {
            book.recordStarted(sessionID: "old-\(index)", agent: .codex, ownedByTapQ: true)
            book.recordEnded(sessionID: "old-\(index)", agent: .codex, ending: "session ended")
        }
        book.recordStarted(sessionID: "live", agent: .claudeCode, workingDirectory: "/live")
        book.recordStarted(sessionID: "one-more", agent: .codex, ownedByTapQ: true)

        XCTAssertLessThanOrEqual(book.eventCount, SessionBook.maximumEvents)
        XCTAssertEqual(book.workingDirectory(sessionID: "live"), "/live")
        XCTAssertEqual(book.focusedSession(agentID: "codex")?.sessionID, "one-more")
        let reopened = makeBook()
        XCTAssertEqual(reopened.eventCount, book.eventCount)
    }
}
