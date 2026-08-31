import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// Pillar A's per-question retrieval — the half M1 deferred to the loop.
///
/// The property worth defending is that this reaches *past* the recent window. M1's grounding
/// carries the last dozen entries unranked; if this suite ever ends up proving that the newest
/// entries come back first, the retrieval has become a second copy of the window and the loop
/// has lost the only thing it could look up that the realtime session could not.
@MainActor
final class WearerMemorySearchTests: XCTestCase {
    private func entry(
        _ kind: WearerDialogueKind,
        _ text: String,
        minutesAgo: Int,
        agent: String = "",
        outcome: String = "",
        tool: String = ""
    ) -> WearerDialogueEntry {
        WearerDialogueEntry(
            kind: kind,
            timestamp: Date(timeIntervalSince1970: 1_000_000)
                .addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            text: text,
            agentDisplayName: agent,
            outcome: outcome,
            toolName: tool
        )
    }

    private var now: Date { Date(timeIntervalSince1970: 1_000_000) }

    func testRelevanceReachesPastTheRecentWindow() async {
        var entries = [
            entry(.wearerSaid, "should we do the database migration this week?",
                  minutesAgo: 4_000),
        ]
        // Twenty newer entries about something else, which is more than the recent window
        // holds — so a recency-first selector would bury the one that answers.
        for index in 0..<20 {
            entries.append(entry(.tapqSaid, "Claude Code finished a turn number \(index)",
                                 minutesAgo: 20 - index))
        }

        let found = WearerMemorySearch.search(
            entries: entries, query: "what did I say about the migration?", now: now
        )

        XCTAssertEqual(found.matches.count, 1)
        XCTAssertEqual(found.matches.first?.index, 1)
        XCTAssertTrue(found.text.contains("should we do the database migration"), found.text)
        XCTAssertTrue(found.text.contains("2 days ago"), found.text)
        XCTAssertEqual(found.droppedEntries, 20)
    }

    func testAnEntryMatchesOnItsAgentAndToolAsWellAsItsText() async {
        let entries = [
            entry(.decision, "run the tests", minutesAgo: 90,
                  agent: "Codex", outcome: "approved", tool: "Bash"),
            entry(.wearerSaid, "unrelated chatter", minutesAgo: 5),
        ]

        let byAgent = WearerMemorySearch.search(
            entries: entries, query: "what did I tell Codex?", now: now
        )
        XCTAssertEqual(byAgent.matches.map(\.index), [1])

        let byTool = WearerMemorySearch.search(
            entries: entries, query: "did I approve the Bash one?", now: now
        )
        XCTAssertEqual(byTool.matches.map(\.index), [1])
        XCTAssertTrue(byTool.text.contains("approved Bash for Codex: run the tests"),
                      byTool.text)
    }

    func testMatchesAreRenderedOldestFirstWhateverOrderTheyRankedIn() async {
        let entries = [
            entry(.wearerSaid, "start the migration", minutesAgo: 300),
            entry(.tapqSaid, "unrelated", minutesAgo: 200),
            entry(.wearerSaid, "is the migration done?", minutesAgo: 100),
        ]

        let found = WearerMemorySearch.search(
            entries: entries, query: "migration", now: now
        )

        XCTAssertEqual(found.matches.map(\.index), [1, 3])
        let first = found.text.range(of: "start the migration")
        let second = found.text.range(of: "is the migration done?")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertTrue(first!.lowerBound < second!.lowerBound, found.text)
    }

    func testAQueryWithNothingToMatchOnFallsBackToTheRecentPast() async {
        let entries = (0..<5).map { entry(.wearerSaid, "line \($0)", minutesAgo: 50 - $0) }

        // Every word is a stop word: this is not a miss, it is a request for the recent past,
        // and answering "nothing matches" would be TapQ pretending not to remember a
        // conversation it has on disk.
        let found = WearerMemorySearch.search(
            entries: entries, query: "what did you just say?", now: now
        )

        XCTAssertEqual(found.matches.count, 5)
        XCTAssertTrue(found.text.contains("No word in the query matched"), found.text)
    }

    func testNoMatchAndNoMemoryAreDifferentSentences() async {
        XCTAssertEqual(
            WearerMemorySearch.search(entries: [], query: "anything", now: now).text,
            WearerMemorySearch.emptyMemoryText
        )
        let entries = [entry(.wearerSaid, "run the tests", minutesAgo: 10)]
        XCTAssertEqual(
            WearerMemorySearch.search(
                entries: entries, query: "kubernetes ingress", now: now
            ).text,
            WearerMemorySearch.noMatchesText
        )
    }

    func testTheResultIsBoundedByCountAndByCharacters() async {
        let entries = (0..<60).map {
            entry(.wearerSaid, "migration note \($0)", minutesAgo: 500 - $0)
        }

        let capped = WearerMemorySearch.search(
            entries: entries, query: "migration", now: now, limit: 5
        )
        XCTAssertEqual(capped.matches.count, 5)
        XCTAssertEqual(capped.droppedEntries, 55)

        let squeezed = WearerMemorySearch.search(
            entries: entries, query: "migration", now: now, budget: 120
        )
        XCTAssertLessThanOrEqual(squeezed.matches.count, 3)
        XCTAssertGreaterThan(squeezed.matches.count, 0)
    }

    func testAgesAreSpokenShaped() async {
        XCTAssertEqual(WearerMemorySearch.age(of: now, now: now), "just now")
        XCTAssertEqual(
            WearerMemorySearch.age(of: now.addingTimeInterval(-60), now: now), "1 minute ago"
        )
        XCTAssertEqual(
            WearerMemorySearch.age(of: now.addingTimeInterval(-3_600), now: now), "1 hour ago"
        )
        XCTAssertEqual(
            WearerMemorySearch.age(of: now.addingTimeInterval(-172_800), now: now),
            "2 days ago"
        )
        // A clock that went backwards is not a reason to say "-3 minutes ago".
        XCTAssertEqual(
            WearerMemorySearch.age(of: now.addingTimeInterval(180), now: now), "just now"
        )
    }

    func testATaskEntryReadsAsItselfRatherThanAsAnUnknownKind() async {
        let entries = [
            entry(.task, "check whether the tests passed", minutesAgo: 30,
                  outcome: WearerTaskLoop.startedOutcome),
            entry(.task, "check whether the tests passed", minutesAgo: 29,
                  outcome: WearerTaskOutcome.finished.rawValue),
        ]

        let found = WearerMemorySearch.search(entries: entries, query: "tests", now: now)

        XCTAssertTrue(
            found.text.contains("The wearer asked TapQ to: check whether the tests passed"),
            found.text
        )
        XCTAssertTrue(
            found.text.contains("TapQ's task (finished): check whether the tests passed"),
            found.text
        )
    }
}
