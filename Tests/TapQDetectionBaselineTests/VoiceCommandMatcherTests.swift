import XCTest
@testable import TapQDetectionBaseline
import TapQGestureContracts

final class VoiceCommandMatcherTests: XCTestCase {
    func testYesVariants() {
        XCTAssertEqual(VoiceCommandMatcher.match("yes please"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("Okay"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("go ahead"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("approve that"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("yes"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("do it"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("okay"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("sure, go ahead"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("go for it"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("confirm"), .yes)
    }

    func testNoVariants() {
        XCTAssertEqual(VoiceCommandMatcher.match("no"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("nope"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("cancel it"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("stop"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("cancel"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("reject that"), .no)
    }

    func testControlCommands() {
        XCTAssertEqual(VoiceCommandMatcher.match("repeat that"), .repeatRequest)
        XCTAssertEqual(VoiceCommandMatcher.match("details"), .details)
        XCTAssertEqual(VoiceCommandMatcher.match("skip"), .skip)
        XCTAssertEqual(VoiceCommandMatcher.match("next option"), .next)
        XCTAssertEqual(VoiceCommandMatcher.match("go back"), .previous)
        XCTAssertEqual(VoiceCommandMatcher.match("pick this"), .select)
    }

    func testNumberSelectionCommands() {
        XCTAssertEqual(VoiceCommandMatcher.match("one"), .number(1))
        XCTAssertEqual(VoiceCommandMatcher.match("two"), .number(2))
        XCTAssertEqual(VoiceCommandMatcher.match("three"), .number(3))
        XCTAssertEqual(VoiceCommandMatcher.match("four"), .number(4))
    }

    func testTokenBoundariesPreventFalseNoMatch() {
        XCTAssertNil(VoiceCommandMatcher.match("the weather is nice"))
        XCTAssertNil(VoiceCommandMatcher.match("now we know"))
    }

    // MARK: - Negation must never approve

    /// The reported defect: "do it" survives inside "don't do it" as a substring, and the
    /// affirmative branch ran before the denial branch, so a refusal approved the action.
    func testNegatedImperativeDeniesInsteadOfApproving() {
        XCTAssertEqual(VoiceCommandMatcher.match("don't do it"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("do not do it"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("dont do it"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("no don't"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("don't"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("please don't go ahead"), .no)
    }

    /// Recognizers emit typographic apostrophes, so the curly spellings are the ones a
    /// live denial actually arrives in.
    func testCurlyApostropheDenialsMatchTheAsciiSpelling() {
        XCTAssertEqual(VoiceCommandMatcher.match("don\u{2019}t do it"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("don\u{02BC}t do it"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("don\u{2018}t do it"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("don\u{FF07}t do it"), .no)
        XCTAssertEqual(
            VoiceCommandMatcher.match("don\u{2019}t"),
            VoiceCommandMatcher.match("don't")
        )
        XCTAssertEqual(
            VoiceCommandMatcher.match("don\u{2019}t approve"),
            VoiceCommandMatcher.match("dont approve")
        )
    }

    /// A negated affirmative is not an approval. It is also not a reliable denial
    /// ("sure, why not"), so the grammar declines to answer and TapQ falls back to the
    /// agent's on-screen prompt.
    func testNegatedAffirmativesResolveToNothingRatherThanYes() {
        XCTAssertNil(VoiceCommandMatcher.match("not okay"))
        XCTAssertNil(VoiceCommandMatcher.match("that is not okay"))
        XCTAssertNil(VoiceCommandMatcher.match("I cannot approve that"))
        XCTAssertNil(VoiceCommandMatcher.match("I can't approve that"))
        XCTAssertNil(VoiceCommandMatcher.match("I can\u{2019}t approve that"))
        XCTAssertNil(VoiceCommandMatcher.match("never approve that"))
        XCTAssertNil(VoiceCommandMatcher.match("that doesn't confirm anything"))
        XCTAssertNil(VoiceCommandMatcher.match("sure, why not"))
    }

    /// An outright denial anywhere in the transcript decides it, whichever side of the
    /// affirmative it lands on — partial transcriptions arrive in arbitrary states of
    /// completeness, so the answer must not depend on word order.
    func testDenialBeatsAnAffirmativeInTheSameUtterance() {
        XCTAssertEqual(VoiceCommandMatcher.match("no, go ahead"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("yes, cancel that"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("approve, no wait"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("okay, stop"), .no)
    }

    /// The exhaustive safety net: no arrangement of a negator and an affirmative may
    /// produce an approval. This is the property the fix exists to hold, so it is
    /// asserted over the cross product rather than over sampled phrases.
    func testNoNegatedUtteranceEverApproves() {
        let negators = [
            "no", "not", "don't", "don\u{2019}t", "dont", "do not", "cannot", "can't",
            "won't", "never", "nope", "nah", "deny", "cancel", "stop", "reject",
            "isn't", "doesn't", "didn't", "couldn't", "wouldn't", "shouldn't", "ain't",
        ]
        let affirmatives = [
            "yes", "yeah", "yep", "yup", "approve", "approved", "sure", "okay", "ok",
            "confirm", "do it", "go ahead", "go for it",
        ]
        for negator in negators {
            for affirmative in affirmatives {
                for utterance in ["\(negator) \(affirmative)", "\(affirmative) \(negator)"] {
                    XCTAssertNotEqual(
                        VoiceCommandMatcher.match(utterance), .yes,
                        "negated utterance approved: \(utterance)"
                    )
                }
            }
        }
    }

    // MARK: - Word-level matching

    /// Negation is matched as whole words, so a word that merely contains a negator's
    /// letters must not deny, and must not block an approval either.
    func testNegatorsMatchWholeWordsOnly() {
        XCTAssertEqual(VoiceCommandMatcher.match("notify me, okay"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("note that, go ahead"), .yes)
        XCTAssertNil(VoiceCommandMatcher.match("cannot decide"))
        XCTAssertNil(VoiceCommandMatcher.match("notify me"))
        XCTAssertNil(VoiceCommandMatcher.match("nothing"))
    }

    /// Multi-word rules match runs of whole words, so an affirmative may not be spliced
    /// out of the middle of longer words.
    func testPhrasesMatchWordRunsNotSubstrings() {
        XCTAssertNil(VoiceCommandMatcher.match("undo items"))
        XCTAssertNil(VoiceCommandMatcher.match("undo notes"))
        XCTAssertEqual(VoiceCommandMatcher.match("one more time"), .repeatRequest)
        XCTAssertEqual(VoiceCommandMatcher.match("this one"), .select)
    }

    /// Apostrophe elision must not disturb ordinary contractions that carry no negation.
    func testContractionsWithoutNegationStillMatch() {
        XCTAssertEqual(VoiceCommandMatcher.match("that's okay"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("let's do it"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("I\u{2019}m sure"), .yes)
    }

    // MARK: - Branches that precede the answer branches

    /// The navigation and deferral rules run before yes/no and keep their own readings,
    /// including the "not sure" deferral that contains a negator.
    func testEarlierBranchesAreUnchangedByNegationHandling() {
        XCTAssertEqual(VoiceCommandMatcher.match("not sure"), .skip)
        XCTAssertEqual(VoiceCommandMatcher.match("I'm not sure"), .skip)
        XCTAssertEqual(VoiceCommandMatcher.match("I\u{2019}m not sure"), .skip)
        XCTAssertEqual(VoiceCommandMatcher.match("next"), .next)
        XCTAssertEqual(VoiceCommandMatcher.match("go back"), .previous)
        XCTAssertEqual(VoiceCommandMatcher.match("this one"), .select)
        XCTAssertEqual(VoiceCommandMatcher.match("two"), .number(2))
        XCTAssertEqual(VoiceCommandMatcher.match("say again"), .repeatRequest)
        XCTAssertEqual(VoiceCommandMatcher.match("tell me more"), .details)
        XCTAssertEqual(VoiceCommandMatcher.match("ask later"), .skip)
        XCTAssertEqual(VoiceCommandMatcher.match("move on"), .next)
        XCTAssertEqual(VoiceCommandMatcher.match("last one"), .previous)
        XCTAssertEqual(VoiceCommandMatcher.match("go with this"), .select)
    }

    func testEmptyAndPunctuationOnlyTranscriptsMatchNothing() {
        XCTAssertNil(VoiceCommandMatcher.match(""))
        XCTAssertNil(VoiceCommandMatcher.match("   "))
        XCTAssertNil(VoiceCommandMatcher.match("\u{2019}\u{2019}"))
        XCTAssertNil(VoiceCommandMatcher.match("..."))
    }
}
