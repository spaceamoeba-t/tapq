import XCTest
import TapQContracts
@testable import TapQContextBaseline

/// The two compositions Rung B's integration added: the fleet status line (RB4) and the
/// whole instruction one grounded answer is asked with (RB3/RB6).
final class SessionRecallStatusTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Status

    func testStatusNamesTheRequestInHandAndCountsTheRest() {
        XCTAssertEqual(
            SessionRecall.status(
                agentDisplayName: "Claude Code",
                summary: "run npm test",
                othersWaiting: 2
            ),
            "Claude Code: run npm test. 2 more waiting."
        )
    }

    func testStatusSaysNothingElseIsWaitingWhenTheQueueIsEmpty() {
        XCTAssertEqual(
            SessionRecall.status(
                agentDisplayName: "Codex",
                summary: "delete the cache",
                othersWaiting: 0
            ),
            "Codex: delete the cache. Nothing else waiting."
        )
    }

    func testStatusUsesTheSingularForOneOtherWaiter() {
        XCTAssertEqual(
            SessionRecall.status(
                agentDisplayName: "Codex", summary: "delete the cache", othersWaiting: 1
            ),
            "Codex: delete the cache. 1 more waiting."
        )
    }

    /// A negative count is a bookkeeping bug somewhere upstream; the wearer should hear a
    /// sentence about it rather than "-1 more waiting."
    func testStatusFloorsAnImpossibleCountAtZero() {
        XCTAssertEqual(
            SessionRecall.status(agentDisplayName: "Codex", summary: "x", othersWaiting: -3),
            "Codex: x. Nothing else waiting."
        )
    }

    func testStatusFallsBackToTheAnonymousAgentAndAPlainWaitingLine() {
        XCTAssertEqual(
            SessionRecall.status(agentDisplayName: nil, summary: nil, othersWaiting: 0),
            "The agent is waiting. Nothing else waiting."
        )
        XCTAssertEqual(
            SessionRecall.status(agentDisplayName: "  ", summary: "   ", othersWaiting: 1),
            "The agent is waiting. 1 more waiting."
        )
    }

    /// The summary is punctuation-trimmed before the period is added, so a question never
    /// reads as "…?." — the same rule the "what changed" prose follows.
    func testStatusDoesNotDoublePunctuateAQuestion() {
        XCTAssertEqual(
            SessionRecall.status(
                agentDisplayName: "Claude Code",
                summary: "Which merge strategy?",
                othersWaiting: 0
            ),
            "Claude Code: Which merge strategy. Nothing else waiting."
        )
    }

    func testStatusStaysWithinItsSpokenBudget() {
        let line = SessionRecall.status(
            agentDisplayName: "Claude Code",
            summary: String(repeating: "very long request ", count: 40),
            othersWaiting: 4
        )

        XCTAssertLessThanOrEqual(line.count, SessionRecall.statusCharacterLimit)
        XCTAssertTrue(line.hasPrefix("Claude Code: very long request"))
    }

    // MARK: - Grounded answers

    func testGroundedAnswerCarriesThePreambleTheContextAndTheQuestion() {
        let digest = SessionRecall.digest(
            events: [event(summary: "run npm test", outcome: .allowed)],
            currentSummary: "delete the build folder"
        )

        let instructions = SessionRecall.groundedAnswer(
            question: "did the tests pass?", digest: digest
        )

        XCTAssertEqual(
            instructions,
            SessionRecall.answeringPreamble + "\n"
                + "Context:\n" + digest + "\n"
                + "Question: did the tests pass?"
        )
    }

    /// The preamble is the whole of the model's licence: answer from context, admit
    /// ignorance, decide nothing. The last clause is the one RB7 depends on.
    func testAnsweringPreambleForbidsDeciding() {
        let preamble = SessionRecall.answeringPreamble.lowercased()
        XCTAssertTrue(preamble.contains("only the context"))
        XCTAssertTrue(preamble.contains("never approve, deny, or choose anything"))
    }

    func testGroundedAnswerSaysSoWhenThereIsNoContext() {
        let instructions = SessionRecall.groundedAnswer(question: "what changed?", digest: "")

        XCTAssertEqual(
            instructions,
            SessionRecall.answeringPreamble + "\n"
                + "Context: nothing has been recorded for this session yet.\n"
                + "Question: what changed?"
        )
    }

    func testGroundedAnswerRefusesAnEmptyQuestion() {
        XCTAssertNil(SessionRecall.groundedAnswer(question: "   \n ", digest: "anything"))
    }

    /// A recognizer that has run away with a nearby conversation must not turn one
    /// question into an unbounded prompt.
    func testGroundedAnswerCapsTheQuestion() {
        let runaway = String(repeating: "and then she said something else ", count: 40)

        let instructions = SessionRecall.groundedAnswer(question: runaway, digest: "")

        XCTAssertNotNil(instructions)
        let asked = instructions?
            .components(separatedBy: "Question: ").last ?? ""
        XCTAssertLessThanOrEqual(asked.count, SessionRecall.questionCharacterLimit)
    }

    /// Redaction by construction, restated at the composition that leaves the machine: a
    /// digest built from events cannot contain a path, because an event has nowhere to
    /// hold one.
    func testGroundedAnswerCarriesNothingFromTheUnspeakableFields() {
        let digest = SessionRecall.digest(
            events: [event(summary: "run npm test", toolName: "Bash", outcome: .allowed)],
            currentSummary: "delete the build folder",
            currentDetail: "the folder has not been rebuilt since Tuesday"
        )

        let instructions = SessionRecall.groundedAnswer(
            question: "what is it doing?", digest: digest
        ) ?? ""

        XCTAssertFalse(instructions.contains("/Users/"))
        XCTAssertFalse(instructions.contains("rm -rf"))
        XCTAssertFalse(instructions.lowercased().contains("permissionmode"))
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
