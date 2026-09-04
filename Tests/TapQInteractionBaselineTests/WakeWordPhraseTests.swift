import XCTest
@testable import TapQInteractionBaseline

/// The wake word's only judgement call: is the phrase in what the recognizer heard?
///
/// Not a `@MainActor` suite and not an async one — `WakeWordPhrase` is a pure value type
/// with no clock, no actor, and no Foundation. That is the point of testing it here rather
/// than through the spotter: the spelling table and the false positives are decidable on
/// Linux, where neither Apple's recognizer nor a microphone exists.
final class WakeWordPhraseTests: XCTestCase {
    private let phrase = WakeWordPhrase("hey tapq")

    // MARK: - The spellings

    /// "TapQ" is not a word, so an on-device recognizer guesses at it. Every guess it is
    /// known to make means the name.
    func testEverySpellingOfTheNameIsTheName() {
        for heard in [
            "hey tapq", "hey tap q", "hey tap queue", "hey tap cue",
            "hey tap-q", "hey tap Q", "Hey TapQ", "HEY TAP QUEUE",
        ] {
            XCTAssertTrue(phrase.isSpoken(in: heard), "should have matched: \(heard)")
        }
    }

    /// Lowercasing, punctuation, and whitespace are all one step: split on anything that is
    /// not a letter or a digit.
    func testPunctuationAndSpacingAreNormalizedAway() {
        XCTAssertTrue(phrase.isSpoken(in: "Hey, TapQ!"))
        XCTAssertTrue(phrase.isSpoken(in: "  hey    tapq  "))
        XCTAssertTrue(phrase.isSpoken(in: "...hey--tapq???"))
    }

    /// A hit anywhere in a partial or final transcript fires, because the recognizer's
    /// segmentation is not the wearer's: the phrase often arrives mid-buffer.
    func testThePhraseIsFoundInsideALongerSentence() {
        XCTAssertTrue(phrase.isSpoken(in: "okay so hey tapq start something for me"))
        XCTAssertTrue(phrase.isSpoken(in: "right, hey tap queue."))
    }

    // MARK: - What must not open a window

    /// The phrase has to be contiguous. "tap the queue" contains both halves of a spelling
    /// with a word between them, and means a queue.
    func testTapTheQueueIsNotTheName() {
        XCTAssertFalse(phrase.isSpoken(in: "tap the queue"))
        XCTAssertFalse(phrase.isSpoken(in: "hey, tap the queue for me"))
    }

    /// The ambiguity guard. "queue up" is a verb, and folding it into the name would open a
    /// window in the middle of a sentence addressed to a person.
    func testQueueAsAVerbIsNotTheName() {
        XCTAssertFalse(phrase.isSpoken(in: "hey, tap queue up the list"))
        XCTAssertFalse(phrase.isSpoken(in: "hey tap cue up the next one"))
    }

    /// Whole words, not substrings: the name inside a longer word is not the name.
    func testTheNameInsideAWordIsNotTheName() {
        XCTAssertFalse(phrase.isSpoken(in: "heytapq"))
        XCTAssertFalse(phrase.isSpoken(in: "they tapqueue"))
    }

    /// A gapped match would find "hey ... tapq" across half a sentence.
    func testTheWordsMustBeAdjacent() {
        XCTAssertFalse(phrase.isSpoken(in: "hey there tapq"))
        XCTAssertFalse(phrase.isSpoken(in: "tapq hey"))
    }

    func testAnEmptyTranscriptMatchesNothing() {
        XCTAssertFalse(phrase.isSpoken(in: ""))
        XCTAssertFalse(phrase.isSpoken(in: "   "))
        XCTAssertFalse(phrase.isSpoken(in: "!!!"))
    }

    /// A phrase that normalizes to nothing must match nothing rather than everything. The
    /// CLI refuses a blank `--wake-word`; this is the same refusal one layer down, where a
    /// future caller that skipped the CLI would land.
    func testAPhraseThatNormalizesToNothingMatchesNothing() {
        let blank = WakeWordPhrase("   ...   ")
        XCTAssertTrue(blank.tokens.isEmpty)
        XCTAssertFalse(blank.isSpoken(in: "hey tapq"))
        XCTAssertFalse(blank.isSpoken(in: "anything at all"))
    }

    // MARK: - A phrase of the operator's own

    func testACustomPhraseIsNormalizedTheSameWay() {
        let custom = WakeWordPhrase("Okay, TapQ")
        XCTAssertEqual(custom.normalized, "okay tapq")
        XCTAssertTrue(custom.isSpoken(in: "okay tap queue, what is going on"))
        XCTAssertTrue(custom.isSpoken(in: "OKAY TAP-Q"))
        XCTAssertFalse(custom.isSpoken(in: "hey tapq"))
        XCTAssertFalse(custom.isSpoken(in: "okay, queue up the build"))
    }

    /// A phrase with no name in it at all still works — nothing here is special-cased to
    /// TapQ's own name except the spelling table, which is inert when it is not used.
    func testAPhraseWithoutTheNameWorks() {
        let custom = WakeWordPhrase("computer")
        XCTAssertTrue(custom.isSpoken(in: "Computer, status?"))
        XCTAssertFalse(custom.isSpoken(in: "the computers are down"))
    }

    func testTheConfiguredSpellingIsKeptForDiagnostics() {
        XCTAssertEqual(WakeWordPhrase("Hey, TapQ!").phrase, "Hey, TapQ!")
        XCTAssertEqual(WakeWordPhrase("Hey, TapQ!").normalized, "hey tapq")
    }
}
