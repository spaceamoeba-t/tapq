import XCTest
@testable import TapQContextBaseline

final class AnsweredQuestionStoreTests: XCTestCase {
    func testFreshTextIsNotARepeat() {
        let store = AnsweredQuestionStore()
        XCTAssertFalse(store.isRepeat(session: "s1", text: "Which approach?"))
    }

    func testNormalizationMatchesCaseWhitespaceAndPunctuation() {
        var store = AnsweredQuestionStore()
        store.record(session: "s1", text: "Which  approach?")
        XCTAssertTrue(store.isRepeat(session: "s1", text: "which approach"))
        XCTAssertTrue(store.isRepeat(session: "s1", text: "  Which APPROACH?  "))
    }

    func testSessionsAreIsolatedAndHistoryIsRetained() {
        var store = AnsweredQuestionStore()
        store.record(session: "s1", text: "Which approach?")
        store.record(session: "s1", text: "Deploy now?")
        XCTAssertTrue(store.isRepeat(session: "s1", text: "Which approach?"))
        XCTAssertTrue(store.isRepeat(session: "s1", text: "Deploy now?"))
        XCTAssertFalse(store.isRepeat(session: "s2", text: "Which approach?"))
    }

    func testCapacityEvictsOnlyTheOldestReply() {
        var store = AnsweredQuestionStore()
        for index in 1...9 {
            store.record(session: "s1", text: "question number \(index)?")
        }
        XCTAssertFalse(store.isRepeat(session: "s1", text: "question number 1?"))
        XCTAssertTrue(store.isRepeat(session: "s1", text: "question number 2?"))
        XCTAssertTrue(store.isRepeat(session: "s1", text: "question number 9?"))
    }

    func testPunctuationOnlyRepliesDoNotCollide() {
        var store = AnsweredQuestionStore()
        store.record(session: "s1", text: "???")
        XCTAssertFalse(store.isRepeat(session: "s1", text: "!?!"))
        XCTAssertTrue(store.isRepeat(session: "s1", text: "???"))
    }
}
