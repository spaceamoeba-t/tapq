import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class SessionWaitRegistryTests: XCTestCase {
    func testBeginAndEndPair() async {
        let registry = SessionWaitRegistry()
        XCTAssertEqual(registry.waitingCount, 0)
        let token = registry.begin(sessionID: "s1", agent: .claudeCode)
        XCTAssertEqual(registry.waitingCount, 1)
        registry.end(token: token)
        XCTAssertEqual(registry.waitingCount, 0)
        XCTAssertTrue(registry.waiting.isEmpty)
    }

    func testWaitersAreReportedOldestFirst() async {
        let registry = SessionWaitRegistry()
        _ = registry.begin(sessionID: "s1", agent: .claudeCode)
        _ = registry.begin(sessionID: "s2", agent: .codex)
        _ = registry.begin(sessionID: "s3", agent: .cursor)
        XCTAssertEqual(registry.waiting.map(\.sessionID), ["s1", "s2", "s3"])
        XCTAssertEqual(registry.waitingAgentNames, ["Claude Code", "Codex", "Cursor"])
    }

    /// The gate serializes parallel tool calls from one session, so the same session is
    /// legitimately waiting more than once — and ending one wait must not end the other.
    func testOneSessionCanWaitTwice() async {
        let registry = SessionWaitRegistry()
        let first = registry.begin(sessionID: "s1", agent: .claudeCode)
        _ = registry.begin(sessionID: "s1", agent: .claudeCode)
        XCTAssertEqual(registry.waitingCount, 2)
        registry.end(token: first)
        XCTAssertEqual(registry.waitingCount, 1)
        XCTAssertEqual(registry.agentDisplayName(forSession: "s1"), "Claude Code")
    }

    /// `defer`-based pairing can reach `end` twice on an unwind path. A registry that
    /// trapped there would turn bookkeeping into a crashed runtime.
    func testEndIsIdempotent() async {
        let registry = SessionWaitRegistry()
        let token = registry.begin(sessionID: "s1", agent: .codex)
        registry.end(token: token)
        registry.end(token: token)
        XCTAssertEqual(registry.waitingCount, 0)
    }

    func testEndingAStaleTokenLeavesOthersAlone() async {
        let registry = SessionWaitRegistry()
        let stale = registry.begin(sessionID: "s1", agent: .codex)
        registry.end(token: stale)
        _ = registry.begin(sessionID: "s2", agent: .cursor)
        registry.end(token: stale)
        XCTAssertEqual(registry.waiting.map(\.sessionID), ["s2"])
    }

    /// The count a status line reports after naming the request in hand.
    func testCountExcludingTheRequestInHand() async {
        let registry = SessionWaitRegistry()
        let mine = registry.begin(sessionID: "s1", agent: .claudeCode)
        _ = registry.begin(sessionID: "s2", agent: .codex)
        _ = registry.begin(sessionID: "s3", agent: .codex)
        XCTAssertEqual(registry.waitingCount, 3)
        XCTAssertEqual(registry.waitingCount(excluding: mine), 2)
        registry.end(token: mine)
        XCTAssertEqual(registry.waitingCount(excluding: mine), 2,
                       "a token that has already been ended excludes nothing")
    }

    /// Two sessions of one agent are one name: a wearer hearing it twice learns nothing
    /// the count did not already say.
    func testAgentNamesAreNamedOnce() async {
        let registry = SessionWaitRegistry()
        _ = registry.begin(sessionID: "s1", agent: .codex)
        _ = registry.begin(sessionID: "s2", agent: .claudeCode)
        _ = registry.begin(sessionID: "s3", agent: .codex)
        XCTAssertEqual(registry.waitingAgentNames, ["Codex", "Claude Code"])
    }

    func testAgentLookupEndsWithTheWait() async {
        let registry = SessionWaitRegistry()
        let token = registry.begin(sessionID: "s1", agent: .openCode)
        XCTAssertEqual(registry.agentDisplayName(forSession: "s1"), "OpenCode")
        XCTAssertNil(registry.agentDisplayName(forSession: "s2"))
        registry.end(token: token)
        XCTAssertNil(registry.agentDisplayName(forSession: "s1"))
    }
}
