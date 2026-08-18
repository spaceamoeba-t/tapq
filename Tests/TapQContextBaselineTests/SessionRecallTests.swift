import XCTest
import TapQContracts
@testable import TapQContextBaseline

final class SessionRecallTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - What changed

    func testEmptyHistorySpeaksTheNothingRecordedLine() {
        XCTAssertEqual(SessionRecall.whatChanged([]), "Nothing recorded yet.")
        XCTAssertEqual(SessionRecall.whatChanged([]), SessionRecall.nothingRecorded)
    }

    func testOneApprovalSpeaksOneSentence() {
        let prose = SessionRecall.whatChanged([
            event(summary: "run npm test", outcome: .allowed),
        ])

        XCTAssertEqual(prose, "Claude Code approved run npm test.")
    }

    func testRecallIsNewestFirstAndCappedAtThreeEvents() {
        let prose = SessionRecall.whatChanged([
            event(summary: "push the branch", outcome: .denied),
            event(summary: "run npm test", outcome: .allowed),
            event(summary: "read the changelog", outcome: .allowed),
            event(summary: "delete the cache", outcome: .allowed),
        ])

        XCTAssertEqual(
            prose,
            "Claude Code denied push the branch. "
                + "Before that, approved run npm test. "
                + "Before that, approved read the changelog."
        )
        XCTAssertFalse(prose.contains("delete the cache"))
    }

    func testASecondAgentIsNamedAgainInTheSameAnswer() {
        let prose = SessionRecall.whatChanged([
            event(summary: "run npm test", outcome: .allowed),
            event(agentDisplayName: "Codex", summary: "push the branch", outcome: .denied),
            event(agentDisplayName: "Codex", summary: "read the log", outcome: .allowed),
        ])

        XCTAssertEqual(
            prose,
            "Claude Code approved run npm test. "
                + "Before that, Codex denied push the branch. "
                + "Before that, approved read the log."
        )
    }

    func testRecallIsDeterministicForTheSameEvents() {
        let events = [
            event(summary: "run npm test", outcome: .allowed),
            event(summary: "Which merge strategy?", outcome: .chose(["Rebase", "Merge"])),
        ]

        XCTAssertEqual(SessionRecall.whatChanged(events), SessionRecall.whatChanged(events))
    }

    func testEveryOutcomeHasItsOwnPhrasing() {
        XCTAssertEqual(
            SessionRecall.whatChanged([event(summary: "run npm test", outcome: .denied)]),
            "Claude Code denied run npm test."
        )
        XCTAssertEqual(
            SessionRecall.whatChanged([event(summary: "run npm test", outcome: .deferred)]),
            "Claude Code deferred run npm test."
        )
        XCTAssertEqual(
            SessionRecall.whatChanged([
                event(
                    kind: .selection,
                    summary: "Which merge strategy?",
                    outcome: .chose(["Rebase"])
                ),
            ]),
            "Claude Code chose Rebase for Which merge strategy."
        )
        XCTAssertEqual(
            SessionRecall.whatChanged([
                event(kind: .stopAnswer, summary: "Ready to ship?", outcome: .answered("yes")),
            ]),
            "Claude Code answered yes to Ready to ship."
        )
        XCTAssertEqual(
            SessionRecall.whatChanged([
                event(kind: .notification, summary: "waiting for input", outcome: .noted),
            ]),
            "Claude Code reported waiting for input."
        )
    }

    func testMultipleChoicesReadAsAList() {
        XCTAssertEqual(
            SessionRecall.whatChanged([
                event(
                    kind: .selection,
                    summary: "Which targets?",
                    outcome: .chose(["iOS", "watchOS", "macOS"])
                ),
            ]),
            "Claude Code chose iOS, watchOS and macOS for Which targets."
        )
    }

    func testAnEmptySummaryFallsBackToTheToolNameThenToAGenericPhrase() {
        XCTAssertEqual(
            SessionRecall.whatChanged([
                event(summary: "", toolName: "Bash", outcome: .allowed),
            ]),
            "Claude Code approved Bash."
        )
        XCTAssertEqual(
            SessionRecall.whatChanged([event(summary: "", outcome: .allowed)]),
            "Claude Code approved a request."
        )
    }

    func testAnUnknownAgentIsSpokenAsTheAgent() {
        XCTAssertEqual(
            SessionRecall.whatChanged([
                event(agentDisplayName: "", summary: "run npm test", outcome: .allowed),
            ]),
            "The agent approved run npm test."
        )
    }

    func testProseStaysWithinItsCharacterCap() {
        let long = String(repeating: "long summary text ", count: 20)
        let prose = SessionRecall.whatChanged([
            event(summary: long, outcome: .allowed),
            event(summary: long, outcome: .denied),
            event(summary: long, outcome: .allowed),
        ])

        XCTAssertLessThanOrEqual(prose.count, SessionRecall.proseCharacterLimit)
        XCTAssertTrue(prose.hasPrefix("Claude Code approved long summary text"))
    }

    func testASingleOversizedSentenceIsTruncatedRatherThanDropped() {
        let prose = SessionRecall.whatChanged([
            event(summary: String(repeating: "x", count: 400), outcome: .allowed),
        ])

        XCTAssertLessThanOrEqual(prose.count, SessionRecall.proseCharacterLimit)
        XCTAssertFalse(prose.isEmpty)
    }

    // MARK: - Digest

    func testDigestIsEmptyWithoutAnythingToSay() {
        XCTAssertEqual(SessionRecall.digest(events: []), "")
    }

    func testDigestCarriesTheOpenRequestAndRecentActivity() {
        let digest = SessionRecall.digest(
            events: [
                event(summary: "run npm test", outcome: .allowed),
                event(summary: "push the branch", outcome: .denied),
            ],
            currentSummary: "delete the build folder",
            currentDetail: "Removes .build so the next build is clean."
        )

        XCTAssertEqual(
            digest,
            """
            Open request: delete the build folder
            Request detail: Removes .build so the next build is clean.
            Recent activity, newest first: Claude Code approved run npm test. \
            Claude Code denied push the branch.
            """
        )
    }

    func testDigestOmitsBlankRequestFields() {
        let digest = SessionRecall.digest(
            events: [event(summary: "run npm test", outcome: .allowed)],
            currentSummary: "   ",
            currentDetail: nil
        )

        XCTAssertEqual(
            digest,
            "Recent activity, newest first: Claude Code approved run npm test."
        )
    }

    func testDigestKeepsAtMostFiveEventsAndStaysWithinItsCap() {
        let events = (1...8).map { event(summary: "step \($0)", outcome: .allowed) }
        let digest = SessionRecall.digest(events: events, currentSummary: "the open one")

        XCTAssertLessThanOrEqual(digest.count, SessionRecall.digestCharacterLimit)
        XCTAssertTrue(digest.contains("step 5"))
        XCTAssertFalse(digest.contains("step 6"))
    }

    func testAnOversizedRequestDetailCannotCrowdOutTheRestOfTheDigest() {
        let long = String(repeating: "detail text ", count: 60)
        let digest = SessionRecall.digest(
            events: [event(summary: "run npm test", outcome: .allowed)],
            currentSummary: "delete the build folder",
            currentDetail: long
        )

        XCTAssertLessThanOrEqual(digest.count, SessionRecall.digestCharacterLimit)
        XCTAssertTrue(digest.hasPrefix("Open request: delete the build folder"))
        XCTAssertTrue(digest.contains("Claude Code approved run npm test."))
    }

    func testDigestIsDeterministic() {
        let events = [event(summary: "run npm test", outcome: .allowed)]

        XCTAssertEqual(
            SessionRecall.digest(events: events, currentSummary: "open one"),
            SessionRecall.digest(events: events, currentSummary: "open one")
        )
    }

    // MARK: - Helpers

    private func event(
        kind: SessionContextEvent.Kind = .approval,
        agentDisplayName: String = "Claude Code",
        summary: String,
        toolName: String = "",
        outcome: SessionContextEvent.Outcome
    ) -> SessionContextEvent {
        SessionContextEvent(
            kind: kind,
            agentDisplayName: agentDisplayName,
            summary: summary,
            toolName: toolName,
            outcome: outcome,
            timestamp: epoch
        )
    }
}
