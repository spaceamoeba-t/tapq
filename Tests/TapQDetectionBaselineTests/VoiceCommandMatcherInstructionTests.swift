import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

/// The dictation grammar sits in front of every other rule, which buys it two obligations:
/// it must catch the phrasings a wearer actually reaches for, and it must not swallow the
/// commands that were already there. Both directions are pinned here, along with the one
/// that matters most — a negated "tell it" is a refusal, not a dictation.
final class VoiceCommandMatcherInstructionTests: XCTestCase {
    // MARK: - Opening the flow

    func testOpenersBeginDictationWithNoTextYet() {
        for transcript in ["new instruction", "New instruction.", "new instructions",
                           "instruction for you", "instruction for Claude",
                           "instructions for the agent"] {
            XCTAssertEqual(VoiceCommandMatcher.match(transcript), .beginInstruction(nil),
                           transcript)
        }
    }

    /// The bare word is how a wearer refers to an instruction that already exists. Opening
    /// dictation on it would put the window into a flow that was only being talked about.
    func testBareInstructionWordDoesNotOpenTheFlow() {
        XCTAssertEqual(VoiceCommandMatcher.match("repeat the instruction"), .repeatRequest)
        XCTAssertNil(VoiceCommandMatcher.match("the instruction was wrong"))
    }

    // MARK: - Dictating in one breath

    func testPrefixCapturesTheRemainder() {
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to run the tests again"),
                       .beginInstruction("run the tests again"))
        XCTAssertEqual(VoiceCommandMatcher.match("tell Claude to open a pull request"),
                       .beginInstruction("open a pull request"))
        XCTAssertEqual(VoiceCommandMatcher.match("tell the agent to stop after this file"),
                       .beginInstruction("stop after this file"))
    }

    /// The captured text is the wearer's, not the grammar's: casing and punctuation survive
    /// because a language model is going to read it, and "readme" is not "README".
    func testCapturedTextKeepsTheWearersOwnWords() {
        XCTAssertEqual(VoiceCommandMatcher.match("Tell it to update the README, then push."),
                       .beginInstruction("update the README, then push."))
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to don\u{2019}t touch the migrations"),
                       .beginInstruction("don\u{2019}t touch the migrations"))
    }

    /// A prefix with nothing after it opens the flow and waits, exactly like an opener.
    func testPrefixWithoutRemainderJustOpensTheFlow() {
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to"), .beginInstruction(nil))
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to..."), .beginInstruction(nil))
    }

    /// The whole reason the branch is first. Every one of these sentences contains a word
    /// that a later rule would have claimed — and one of them would have approved the
    /// request the wearer was dictating past.
    func testDictatedSentencesOutrankTheCommandGrammar() {
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to explain the diff"),
                       .beginInstruction("explain the diff"))
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to go ahead and merge"),
                       .beginInstruction("go ahead and merge"))
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to pick the second option"),
                       .beginInstruction("pick the second option"))
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to skip the slow tests"),
                       .beginInstruction("skip the slow tests"))
    }

    /// An affirmative in front of the trigger is a filler word, not an answer: "okay, tell
    /// it to …" must dictate rather than approve whatever is on the table.
    func testAffirmativeBeforeTheTriggerStillDictates() {
        XCTAssertEqual(VoiceCommandMatcher.match("okay, tell it to run the linter"),
                       .beginInstruction("run the linter"))
        XCTAssertEqual(VoiceCommandMatcher.match("sure, new instruction"),
                       .beginInstruction(nil))
    }

    // MARK: - Negation

    /// The named case: a wearer refusing to send anything must not open dictation, and must
    /// not have their refusal read as an approval either.
    func testNegatedDictationDoesNotBegin() {
        for transcript in ["don't tell it anything",
                           "don\u{2019}t tell it to run the tests",
                           "no, tell it to run the tests",
                           "not a new instruction",
                           "cancel, new instruction"] {
            let match = VoiceCommandMatcher.match(transcript)
            XCTAssertNotEqual(match, .beginInstruction(nil), transcript)
            XCTAssertNotEqual(match, .beginInstruction("run the tests"), transcript)
            XCTAssertNotEqual(match, .yes, "\(transcript) must never approve")
        }
    }

    /// A denial that precedes the trigger is still a denial — the transcript falls through
    /// to the branch it would have reached if dictation had never been taught.
    func testNegatedDictationFallsThroughToDenial() {
        XCTAssertEqual(VoiceCommandMatcher.match("don't tell it to run the tests"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("no, new instruction"), .no)
    }

    /// The guard stops at the trigger on purpose. Everything after it is the sentence the
    /// wearer wants the agent to act on, and instructions are allowed to contain the word
    /// "stop" — that is frequently the whole point.
    func testNegatorsInsideTheDictatedTextAreJustWords() {
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to stop the server"),
                       .beginInstruction("stop the server"))
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to not deploy yet"),
                       .beginInstruction("not deploy yet"))
        XCTAssertEqual(VoiceCommandMatcher.match("tell it to cancel the run"),
                       .beginInstruction("cancel the run"))
    }

    // MARK: - Everything that was already there

    /// "Tell me" is the details command and stays the details command; the dictation
    /// prefixes all name the agent explicitly.
    func testExistingCommandsAreUnaffected() {
        XCTAssertEqual(VoiceCommandMatcher.match("tell me more"), .details)
        XCTAssertEqual(VoiceCommandMatcher.match("yes"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("do it"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("no"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("what's the status"), .status)
        XCTAssertEqual(VoiceCommandMatcher.match("what did you just do"), .whatChanged)
        XCTAssertEqual(VoiceCommandMatcher.match("next option"), .next)
        XCTAssertEqual(VoiceCommandMatcher.match("second"), .number(2))
        XCTAssertNil(VoiceCommandMatcher.match("how long has this been running"))
    }
}
