import XCTest
import TapQContracts

/// Instructing is a distinct act from authorizing, and the contract layer is where the
/// distinction has to be structural: a case of its own, carrying its own payload, equal to
/// nothing that decides anything.
final class InstructionIntentTests: XCTestCase {
    func testBeginInstructionMapsToItsOwnIntentAndCarriesItsText() {
        XCTAssertEqual(VoiceCommand.beginInstruction(nil).intent, .beginInstruction(nil))
        XCTAssertEqual(VoiceCommand.beginInstruction("run the tests").intent,
                       .beginInstruction("run the tests"))
    }

    func testBeginInstructionIsNotADecision() {
        for intent: InputIntent in [.beginInstruction(nil), .beginInstruction("ship it")] {
            XCTAssertNotEqual(intent, .allow)
            XCTAssertNotEqual(intent, .deny)
            XCTAssertNotEqual(intent, .deferToPrompt)
            XCTAssertNotEqual(intent, .select)
            XCTAssertNotEqual(intent, .status)
        }
    }

    /// The payload participates in equality, so an empty dictation and a dictated sentence
    /// are different things to every switch that reads them.
    func testEqualityIncludesTheText() {
        XCTAssertEqual(VoiceCommand.beginInstruction("a"), .beginInstruction("a"))
        XCTAssertNotEqual(VoiceCommand.beginInstruction("a"), .beginInstruction("b"))
        XCTAssertNotEqual(VoiceCommand.beginInstruction(nil), .beginInstruction(""))
        XCTAssertEqual(InputIntent.beginInstruction(nil), .beginInstruction(nil))
        XCTAssertNotEqual(InputIntent.beginInstruction("a"), .freeform("a"))
    }

    /// A hand-written `==` plus a hand-written intent mapping is exactly where a new case
    /// silently changes an old one.
    func testExistingMappingsAreUnchanged() {
        XCTAssertEqual(VoiceCommand.yes.intent, .allow)
        XCTAssertEqual(VoiceCommand.no.intent, .deny)
        XCTAssertEqual(VoiceCommand.skip.intent, .deferToPrompt)
        XCTAssertEqual(VoiceCommand.status.intent, .status)
        XCTAssertEqual(VoiceCommand.whatChanged.intent, .whatChanged)
        XCTAssertEqual(VoiceCommand.number(3).intent, .selectByNumber(3))
        XCTAssertEqual(VoiceCommand.freeform("ship it").intent, .freeform("ship it"))
    }
}
