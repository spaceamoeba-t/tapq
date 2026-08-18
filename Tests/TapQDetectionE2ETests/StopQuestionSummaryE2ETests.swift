import XCTest
import TapQContextBaseline
import TapQContracts
@testable import TapQInteractionBaseline

/// Tier 1: a summarized final reply, from the agent's text to what the wearer hears.
///
/// The classifier and the summarizer are stubs — what a model returns is its own tests'
/// subject — and everything after them is the shipping stack: the coordinator builds the
/// request, the real `InteractionController` and presenter turn it into utterances, and
/// real IMU traces and transcripts answer it.
@MainActor
final class StopQuestionSummaryE2ETests: XCTestCase {
    private struct FixedClassifier: ResponseQuestionClassifying {
        let classification: ResponseQuestionClassification?
        func classify(_ text: String) async -> ResponseQuestionClassification? {
            classification
        }
    }

    private struct FixedSummarizer: SpokenSummarizing {
        let summary: SpokenSummary?
        func summarize(_ text: String) async -> SpokenSummary? { summary }
    }

    private static let finalReply = """
    I finished the importer. It now streams rows instead of loading the whole file, \
    and the retry budget is three attempts. Should I delete the old importer?
    """

    private func coordinator(
        harness: DetectionPathHarness,
        summarizer: (any SpokenSummarizing)?
    ) -> StopQuestionCoordinator {
        StopQuestionCoordinator(
            classifier: FixedClassifier(
                classification: .yesNo(question: "Delete the old importer")
            ),
            summarizer: summarizer,
            runSelection: { _, _ in .noSelection },
            runApproval: { [harness] request, deadline in
                await harness.interaction.resolve(request, deadline: deadline)
            }
        )
    }

    /// The summary sentence introduces the question, and "details" — which used to answer
    /// "No further details." on every stop question — speaks the rest of the summary.
    func testSummarizedStopQuestionSpeaksSentenceThenDetail() async {
        let harness = DetectionPathHarness()
        let summarizer = FixedSummarizer(summary: SpokenSummary(
            sentence: "The importer now streams rows.",
            detail: "It streams rows instead of loading the whole file, and retries three times."
        ))
        let reply = Task {
            await self.coordinator(harness: harness, summarizer: summarizer)
                .handle(sessionID: "s1", text: Self.finalReply)
        }

        let firstWindow = await harness.waitForWindow(1)
        XCTAssertTrue(firstWindow, "the stop question opened no input window")
        XCTAssertTrue(
            harness.speech.said(
                "The agent: The importer now streams rows. Delete the old importer. Yes or no?"
            ),
            "the summary sentence introduces the question the user answers"
        )
        harness.hear("details")

        let secondWindow = await harness.waitForWindow(2)
        XCTAssertTrue(secondWindow, "asking for details must re-listen")
        XCTAssertTrue(
            harness.speech.said(
                "It streams rows instead of loading the whole file, and retries three times."
            ),
            "details speaks the summary's detail, not 'No further details.'"
        )
        XCTAssertFalse(harness.speech.said("No further details."))
        harness.feed(TraceGenerators.doubleNod())

        let answer = await reply.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(
            answer,
            "The user answered hands-free. For the question 'Delete the old importer', "
                + "they chose: 'Yes'. Proceed with this choice without re-asking."
        )
    }

    /// The `off` composition, end to end: no summarizer, and every utterance is the one
    /// the same stop question produced before spoken summaries existed.
    func testStopQuestionWithoutSummarizerSpeaksTodaysWords() async {
        let harness = DetectionPathHarness()
        let reply = Task {
            await self.coordinator(harness: harness, summarizer: nil)
                .handle(sessionID: "s1", text: Self.finalReply)
        }

        let firstWindow = await harness.waitForWindow(1)
        XCTAssertTrue(firstWindow)
        XCTAssertTrue(
            harness.speech.said("The agent: Delete the old importer. Yes or no?"),
            "with no summarizer the prompt is the classified question alone"
        )
        harness.hear("details")

        let secondWindow = await harness.waitForWindow(2)
        XCTAssertTrue(secondWindow)
        XCTAssertTrue(harness.speech.said("No further details."))
        harness.feed(TraceGenerators.doubleShake())

        let answer = await reply.value
        harness.assertWatchdogDidNotFire()
        XCTAssertTrue(answer?.contains("they chose: 'No'") == true)
    }
}
