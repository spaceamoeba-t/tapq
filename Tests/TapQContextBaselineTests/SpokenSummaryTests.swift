import XCTest
@testable import TapQContextBaseline

final class SpokenSummaryTests: XCTestCase {
    func testShortTextIsNormalizedNotTruncated() {
        let summary = SpokenSummary(
            sentence: "  Renamed\tthe\nvoice principle.  ",
            detail: "Two files changed.\n\nNo tests were added."
        )

        XCTAssertEqual(summary.sentence, "Renamed the voice principle.")
        XCTAssertEqual(summary.detail, "Two files changed. No tests were added.")
    }

    func testSentenceKeepsOnlyTheFirstSentence() {
        let summary = SpokenSummary(
            sentence: "Renamed the principle. Then updated the README. And the tests.",
            detail: ""
        )

        XCTAssertEqual(summary.sentence, "Renamed the principle.")
        XCTAssertEqual(summary.detail, "")
    }

    func testSentenceIgnoresAbbreviationAndListNumberPeriods() {
        XCTAssertEqual(
            SpokenSummary(sentence: "Updated e.g. the parser. Rebuilt it.", detail: "").sentence,
            "Updated e.g. the parser."
        )
        XCTAssertEqual(
            SpokenSummary(sentence: "1. Fixed the flake. Next one.", detail: "").sentence,
            "1. Fixed the flake."
        )
    }

    func testOversizedSentenceTruncatesOnAWordBoundary() {
        let words = Array(repeating: "alpha", count: 60).joined(separator: " ")
        let summary = SpokenSummary(sentence: words, detail: "")

        // 20 words of five characters plus 19 separators is the largest run under 120.
        XCTAssertEqual(summary.sentence, Array(repeating: "alpha", count: 20).joined(separator: " "))
        XCTAssertLessThanOrEqual(summary.sentence.count, SpokenSummary.sentenceCharacterLimit)
    }

    func testTruncationDropsDanglingPunctuation() {
        let head = Array(repeating: "alpha", count: 19).joined(separator: " ")
        let summary = SpokenSummary(sentence: head + ", elaborate additional context", detail: "")

        XCTAssertEqual(summary.sentence, head)
        XCTAssertFalse(summary.sentence.hasSuffix(","))
    }

    func testDetailPrefersASentenceBoundary() {
        let text = (1...30).map { "Step \($0) finished the migration." }.joined(separator: " ")
        let summary = SpokenSummary(sentence: "Migration ran.", detail: text)

        XCTAssertLessThanOrEqual(summary.detail.count, SpokenSummary.detailCharacterLimit)
        XCTAssertTrue(summary.detail.hasSuffix("migration."))
        XCTAssertTrue(summary.detail.hasPrefix("Step 1 finished"))
        XCTAssertGreaterThan(summary.detail.count, 250, "greedy accumulation should fill the cap")
    }

    func testDetailWordTruncatesWhenNoSentenceFits() {
        let words = Array(repeating: "alpha", count: 200).joined(separator: " ")
        let summary = SpokenSummary(sentence: "Long detail.", detail: words)

        XCTAssertEqual(summary.detail, Array(repeating: "alpha", count: 53).joined(separator: " "))
        XCTAssertLessThanOrEqual(summary.detail.count, SpokenSummary.detailCharacterLimit)
    }

    func testSingleWordLongerThanTheCapIsCutHard() {
        let blob = String(repeating: "z", count: 400)
        let summary = SpokenSummary(sentence: blob, detail: blob)

        XCTAssertEqual(summary.sentence.count, SpokenSummary.sentenceCharacterLimit)
        XCTAssertEqual(summary.detail.count, SpokenSummary.detailCharacterLimit)
    }

    func testMakeRejectsAnEmptySentence() {
        XCTAssertNil(SpokenSummary.make(sentence: "   \n ", detail: "Detail survives."))
        XCTAssertNotNil(SpokenSummary.make(sentence: "Done.", detail: ""))
    }

    func testTruncationIsDeterministic() {
        let text = "Reviewed the adapters, refactored the pump, " + String(repeating: "x y ", count: 90)
        let first = SpokenSummary(sentence: text, detail: text)
        let second = SpokenSummary(sentence: text, detail: text)

        XCTAssertEqual(first, second)
    }
}
