import XCTest
@testable import TapQContextBaseline

final class HeuristicSpokenSummarizerTests: XCTestCase {
    private let summarizer = HeuristicSpokenSummarizer()

    func testSpeaksTheOpeningSentenceOfProse() async {
        let summary = await summarizer.summarize(
            "I renamed the voice principle. The README and the plan now agree."
        )

        XCTAssertEqual(summary?.sentence, "I renamed the voice principle.")
        XCTAssertEqual(
            summary?.detail,
            "I renamed the voice principle. The README and the plan now agree."
        )
    }

    func testFencedCodeIsNeverSpoken() async {
        let summary = await summarizer.summarize("""
            Added the retry loop.

            ```swift
            func retry() async throws { try await send() }
            ```

            Tests cover the timeout path.
            """)

        XCTAssertEqual(summary?.sentence, "Added the retry loop.")
        XCTAssertEqual(summary?.detail, "Added the retry loop. Tests cover the timeout path.")
    }

    func testInlineMarkdownIsUnwrapped() async {
        let summary = await summarizer.summarize(
            "Updated **`VoiceBackend`** and the [plan](docs/PLAN.md) together."
        )

        XCTAssertEqual(
            summary?.sentence,
            "Updated VoiceBackend and the plan together."
        )
    }

    func testHeadingsAndBulletsBecomeSeparateSentences() async {
        let summary = await summarizer.summarize("""
            ## Summary

            - Fixed the flake
            - Added a regression test
            """)

        XCTAssertEqual(summary?.sentence, "Summary.")
        XCTAssertEqual(summary?.detail, "Summary. Fixed the flake. Added a regression test.")
    }

    func testNumberedListsLoseTheirMarkers() async {
        let summary = await summarizer.summarize("""
            1) Rebuilt the bundle
            2) Reinstalled the hook
            """)

        XCTAssertEqual(summary?.sentence, "Rebuilt the bundle.")
        XCTAssertEqual(summary?.detail, "Rebuilt the bundle. Reinstalled the hook.")
    }

    func testCapsAreEnforcedOnLongReplies() async throws {
        let text = (1...60).map { "Step \($0) rewrote another adapter file." }.joined(separator: " ")
        let produced = await summarizer.summarize(text)
        let summary = try XCTUnwrap(produced)

        XCTAssertEqual(summary.sentence, "Step 1 rewrote another adapter file.")
        XCTAssertLessThanOrEqual(summary.sentence.count, SpokenSummary.sentenceCharacterLimit)
        XCTAssertLessThanOrEqual(summary.detail.count, SpokenSummary.detailCharacterLimit)
        XCTAssertTrue(summary.detail.hasSuffix("file."))
    }

    func testTextWithoutSpeakableContentReturnsNil() async {
        let blank = await summarizer.summarize("   \n\n\t ")
        XCTAssertNil(blank)

        let codeOnly = await summarizer.summarize("""
            ```
            swift test --package-path .
            ```
            """)
        XCTAssertNil(codeOnly)

        let empty = await summarizer.summarize("")
        XCTAssertNil(empty)
    }

    func testSummarizationIsDeterministic() async {
        let text = """
            ### Result

            Shipped the **encoder**, see `Sources/Encoder.swift`.

            - One: trims the window
            - Two: normalizes the axes
            """

        let first = await summarizer.summarize(text)
        let second = await summarizer.summarize(text)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }
}
