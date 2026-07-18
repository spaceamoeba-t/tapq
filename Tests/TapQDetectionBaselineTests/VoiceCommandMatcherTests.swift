import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

final class VoiceCommandMatcherTests: XCTestCase {
    func testYesVariants() {
        XCTAssertEqual(VoiceCommandMatcher.match("yes please"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("Okay"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("go ahead"), .yes)
        XCTAssertEqual(VoiceCommandMatcher.match("approve that"), .yes)
    }

    func testNoVariants() {
        XCTAssertEqual(VoiceCommandMatcher.match("no"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("nope"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("cancel it"), .no)
        XCTAssertEqual(VoiceCommandMatcher.match("stop"), .no)
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
}
