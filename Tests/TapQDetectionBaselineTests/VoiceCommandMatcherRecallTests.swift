import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

/// The recall grammar earns its place only if it can never be mistaken for an answer.
/// These tests pin the two directions that matter: the questions are recognized, and a
/// question that happens to carry an affirmative or a negator still resolves to the
/// question rather than to `.yes` or `.no`.
final class VoiceCommandMatcherRecallTests: XCTestCase {
    func testStatusVariants() {
        XCTAssertEqual(VoiceCommandMatcher.match("status"), .status)
        XCTAssertEqual(VoiceCommandMatcher.match("what's the status"), .status)
        XCTAssertEqual(VoiceCommandMatcher.match("What is the status?"), .status)
        XCTAssertEqual(VoiceCommandMatcher.match("who's waiting"), .status)
        XCTAssertEqual(VoiceCommandMatcher.match("who is waiting right now"), .status)
    }

    /// Recognizers emit the typographic apostrophe far more often than the ASCII one, and
    /// "who's waiting" is one of the two phrases that carries one.
    func testTypographicApostropheStillMatches() {
        XCTAssertEqual(VoiceCommandMatcher.match("who\u{2019}s waiting"), .status)
        XCTAssertEqual(VoiceCommandMatcher.match("what\u{2019}s the status"), .status)
    }

    func testWhatChangedVariants() {
        XCTAssertEqual(VoiceCommandMatcher.match("what changed"), .whatChanged)
        XCTAssertEqual(VoiceCommandMatcher.match("What did you change?"), .whatChanged)
        XCTAssertEqual(VoiceCommandMatcher.match("what did you do"), .whatChanged)
        XCTAssertEqual(VoiceCommandMatcher.match("what has changed since I left"), .whatChanged)
        XCTAssertEqual(VoiceCommandMatcher.match("what have you done"), .whatChanged)
    }

    /// The reported failure class for the affirmative guard, asked in the recall grammar's
    /// words: a negated request for information must not approve anything.
    func testNegatedRecallDoesNotApprove() {
        for transcript in ["don't tell me the status",
                           "no, what's the status",
                           "not now, what did you do"] {
            let match = VoiceCommandMatcher.match(transcript)
            XCTAssertNotEqual(match, .yes, "\(transcript) must never approve")
        }
    }

    /// An affirmative word inside the question does not make it an answer. This is why the
    /// branches sit ahead of the yes guard rather than after it.
    func testRecallOutranksTheAffirmative() {
        XCTAssertEqual(VoiceCommandMatcher.match("okay, what's the status"), .status)
        XCTAssertEqual(VoiceCommandMatcher.match("sure, what did you do"), .whatChanged)
    }

    /// Two questions in one breath resolve to the more specific one the matcher reaches
    /// first — deterministically, and never to an answer.
    func testStatusIsReachedBeforeWhatChanged() {
        XCTAssertEqual(VoiceCommandMatcher.match("what changed, and what's the status"), .status)
    }

    /// Every command that existed before recall still matches what it matched, including
    /// the ones whose words sit near the new phrases.
    func testExistingCommandsAreUnaffected() {
        XCTAssertEqual(VoiceCommandMatcher.match("yes"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("do it"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("no"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("details"), .details)
        XCTAssertEqual(VoiceCommandMatcher.match("tell me more"), .details)
        XCTAssertEqual(VoiceCommandMatcher.match("repeat that"), .repeatRequest)
        XCTAssertEqual(VoiceCommandMatcher.match("next option"), .next)
        XCTAssertEqual(VoiceCommandMatcher.match("first"), .number(1))
    }

    /// A question the grammar does not know is still `nil`, not a guess: an unmatched
    /// transcript leaves the request to the on-screen prompt, which is recoverable.
    func testUnknownQuestionsStillFailOpen() {
        XCTAssertNil(VoiceCommandMatcher.match("how long has this been running"))
        XCTAssertNil(VoiceCommandMatcher.match("what's for lunch"))
    }
}
