import XCTest
@testable import TapQKernel

/// D5: a floor and a cap per delegate, and the one sentence that refuses the rest.
final class VersionRangeTests: XCTestCase {
    private let claude = VersionRange(floor: "2.1.260", cap: "2.1.293")
    private let codex = VersionRange(floor: "0.161.0", cap: "0.161")

    func testBothEndsAreInclusive() {
        XCTAssertTrue(claude.contains("2.1.260"))
        XCTAssertTrue(claude.contains("2.1.283"))
        XCTAssertTrue(claude.contains("2.1.293"))
    }

    func testAFullCapAdmitsNothingAboveIt() {
        XCTAssertFalse(claude.contains("2.1.294"))
        XCTAssertFalse(claude.contains("2.1.300"))
        XCTAssertFalse(claude.contains("2.2.0"))
        XCTAssertFalse(claude.contains("3.0.0"))
    }

    func testNothingBelowTheFloor() {
        XCTAssertFalse(claude.contains("2.1.259"))
        XCTAssertFalse(claude.contains("1.9.999"))
        XCTAssertFalse(codex.contains("0.160.9"))
    }

    func testAShortCapIsAPrefix() {
        XCTAssertTrue(codex.contains("0.161.0"))
        XCTAssertTrue(codex.contains("0.161.7"))
        XCTAssertTrue(codex.contains("0.161.120"))
        XCTAssertFalse(codex.contains("0.162.0"))
        XCTAssertFalse(codex.contains("1.0.0"))
    }

    func testComparisonIsNumericNotLexical() {
        let range = VersionRange(floor: "1.9.0", cap: "1.10.0")
        XCTAssertTrue(range.contains("1.10.0"))
        XCTAssertTrue(range.contains("1.9.10"))
        XCTAssertFalse(range.contains("1.2.0"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(VersionRange(floor: "2.1", cap: "2.1.293").contains("2.1.0"))
        XCTAssertTrue(claude.contains("2.1.293.0"))
        XCTAssertFalse(claude.contains("2.1"))
    }

    func testAVersionThatIsNotDottedNumericIsNeverContained() {
        for found in ["", "2.1.283 (Claude Code)", "0.161.0-alpha.1", "2..283", "v2.1.283", "2.1.x"] {
            XCTAssertFalse(claude.contains(found), found)
            XCTAssertFalse(codex.contains(found), found)
        }
    }

    func testTheRefusalNamesTheAgentWhatWasFoundAndTheRange() {
        XCTAssertEqual(claude.refusal(for: .claude, found: "2.1.300"),
                       "Claude Code 2.1.300 is not supported. TapQ supports 2.1.260 through 2.1.293.")
        XCTAssertEqual(codex.refusal(for: .codex, found: "0.162.0"),
                       "Codex 0.162.0 is not supported. TapQ supports 0.161.0 through 0.161.x.")
    }
}
