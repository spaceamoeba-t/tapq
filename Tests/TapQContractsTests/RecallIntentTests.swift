import XCTest
import TapQContracts

/// The recall commands are informational everywhere they are handled, and the contract
/// layer is where that starts: they map to intents of their own rather than borrowing an
/// existing one, so no handler can reach an approval by pattern-matching them loosely.
final class RecallIntentTests: XCTestCase {
    func testRecallCommandsMapToTheirOwnIntents() {
        XCTAssertEqual(VoiceCommand.status.intent, .status)
        XCTAssertEqual(VoiceCommand.whatChanged.intent, .whatChanged)
    }

    func testRecallIntentsAreNotDecisions() {
        for intent in [InputIntent.status, .whatChanged] {
            XCTAssertNotEqual(intent, .allow)
            XCTAssertNotEqual(intent, .deny)
            XCTAssertNotEqual(intent, .deferToPrompt)
            XCTAssertNotEqual(intent, .select)
        }
    }

    func testRecallCasesCompareByIdentity() {
        XCTAssertEqual(VoiceCommand.status, .status)
        XCTAssertEqual(VoiceCommand.whatChanged, .whatChanged)
        XCTAssertNotEqual(VoiceCommand.status, .whatChanged)
        XCTAssertNotEqual(VoiceCommand.status, .yes)
        XCTAssertEqual(InputIntent.status, .status)
        XCTAssertEqual(InputIntent.whatChanged, .whatChanged)
        XCTAssertNotEqual(InputIntent.status, .whatChanged)
    }

    /// The existing mappings are what every caller written before recall existed depends
    /// on; adding cases to an enum with a hand-written `==` is exactly where they would
    /// silently change.
    func testExistingMappingsAreUnchanged() {
        XCTAssertEqual(VoiceCommand.yes.intent, .allow)
        XCTAssertEqual(VoiceCommand.no.intent, .deny)
        XCTAssertEqual(VoiceCommand.skip.intent, .deferToPrompt)
        XCTAssertEqual(VoiceCommand.details.intent, .details)
        XCTAssertEqual(VoiceCommand.number(2).intent, .selectByNumber(2))
        XCTAssertEqual(VoiceCommand.freeform("ship it").intent, .freeform("ship it"))
    }
}
