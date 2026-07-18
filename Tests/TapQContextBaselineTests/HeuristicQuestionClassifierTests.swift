import XCTest
@testable import TapQContextBaseline
import TapQContracts

final class HeuristicQuestionClassifierTests: XCTestCase {
    let classifier = HeuristicQuestionClassifier()

    // MARK: - Helpers

    private func assertNoQuestion(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .noQuestion = classifier.classifySync(text) else {
            return XCTFail("expected .noQuestion", file: file, line: line)
        }
    }

    @discardableResult
    private func assertMultiOption(
        _ text: String, expectedCount: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> (question: String, options: [SelectionOption])? {
        guard case .multiOption(let question, let options) = classifier.classifySync(text) else {
            XCTFail("expected .multiOption", file: file, line: line)
            return nil
        }
        XCTAssertEqual(options.count, expectedCount, "option count", file: file, line: line)
        return (question, options)
    }

    // MARK: - True negatives

    func testEmptyTextIsNoQuestion() {
        assertNoQuestion("")
    }

    func testStatementIsNoQuestion() {
        assertNoQuestion("I've updated the file and all tests pass.")
    }

    func testOpenEndedQuestionIsNoQuestion() {
        assertNoQuestion("What would you like to do next?")
    }

    func testYesNoProseIsNoQuestionForHeuristic() {
        // yes/no detection is FM-only by design (bias toward false negatives).
        assertNoQuestion("Should I proceed with the refactor?")
    }

    func testNumberedListWithoutQuestionMarkIsNoQuestion() {
        let text = """
        Here are the files I modified:

        1. src/App.tsx
        2. src/index.css
        3. tests/App.test.tsx
        """
        assertNoQuestion(text)
    }

    func testFilePathOptionsRejected() {
        let text = """
        Which file should I fix?

        1. src/App.tsx
        2. src/index.css
        3. tests/App.test.tsx
        """
        assertNoQuestion(text)
    }

    func testQuestionTooFarFromOptionsRejected() {
        let text = """
        Should I proceed?

        Here is a long explanation paragraph that provides context about the changes.

        Another paragraph with more detail about the architecture decisions.

        Yet another paragraph discussing trade-offs.

        1. First item in an unrelated list
        2. Second item in an unrelated list
        """
        assertNoQuestion(text)
    }

    // MARK: - Numbered options

    func testNumberedOptionsAfterQuestion() {
        let text = """
        Which approach would you prefer?

        1) Simple - just patch the function
        2) Complex - refactor the whole module
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertEqual(result?.options[0].label, "Simple")
        XCTAssertEqual(result?.options[0].description, "just patch the function")
        XCTAssertEqual(result?.options[1].label, "Complex")
        XCTAssertEqual(result?.options[1].description, "refactor the whole module")
        XCTAssertTrue(result?.question.contains("approach") ?? false)
    }

    func testNumberedOptionsWithDotSeparator() {
        let text = """
        Which one?

        1. Alpha
        2. Beta
        3. Gamma
        """
        let result = assertMultiOption(text, expectedCount: 3)
        XCTAssertEqual(result?.options[0].label, "Alpha")
        XCTAssertEqual(result?.options[2].label, "Gamma")
    }

    func testQuestionOnLineDirectlyAboveOptions() {
        let text = """
        Which approach?
        1) Simple
        2) Complex
        """
        assertMultiOption(text, expectedCount: 2)
    }

    // MARK: - Lettered options

    func testLetteredOptions() {
        let text = """
        Which one do you prefer?

        A) Incremental refactor
        B) Big bang rewrite
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertEqual(result?.options[0].label, "Incremental refactor")
        XCTAssertEqual(result?.options[1].label, "Big bang rewrite")
    }

    func testLetteredOptionsMustStartWithA() {
        let text = """
        Which?

        C) Not starting with A
        D) Should be rejected
        """
        assertNoQuestion(text)
    }

    // MARK: - Bold options

    func testBoldOptionsWithDash() {
        let text = """
        Choose an approach?

        **Simple** - just patch the function
        **Complex** - refactor the whole module
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertEqual(result?.options[0].label, "Simple")
        XCTAssertEqual(result?.options[0].description, "just patch the function")
    }

    func testBoldOptionsWithColon() {
        let text = """
        Which strategy?

        **Incremental**: split into smaller PRs
        **Big bang**: one large PR
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertEqual(result?.options[0].label, "Incremental")
        XCTAssertEqual(result?.options[0].description, "split into smaller PRs")
    }

    // MARK: - Question extraction

    func testQuestionFoundAfterOptions() {
        let text = """
        1) Patch it
        2) Rewrite it

        Which approach do you prefer?
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertTrue(result?.question.contains("prefer") ?? false)
    }

    func testQuestionOneParagraphAfterOptionsIsFound() {
        let text = """
        1) Patch it
        2) Rewrite it

        Both approaches carry some risk.

        Which approach do you prefer?
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertTrue(result?.question.contains("prefer") ?? false)
    }

    func testQuestionThreeParagraphsAfterOptionsRejected() {
        let text = """
        1) Patch it
        2) Rewrite it

        First filler paragraph with context.

        Second filler paragraph with more context.

        Which approach do you prefer?
        """
        assertNoQuestion(text)
    }

    func testLongContextBeforeQuestion() {
        let text = """
        I analyzed the codebase thoroughly and found several issues with the authentication module. The token handling is inconsistent and the session management has race conditions.

        Which fix approach would you prefer?

        1) Patch - fix the specific bugs
        2) Rewrite - redo the auth module
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertTrue(result?.question.contains("fix approach") ?? false)
    }

    func testQuestionSentenceExtractedFromParagraph() {
        let text = """
        I've identified two options. Which would you prefer?

        1) Option A
        2) Option B
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertTrue(result?.question.contains("Which would you prefer?") ?? false)
    }

    // MARK: - Option parsing

    func testOptionWithoutDescription() {
        let text = """
        Pick one?

        1) Simple
        2) Complex
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertEqual(result?.options[0].label, "Simple")
        XCTAssertEqual(result?.options[0].description, "")
    }

    func testOptionWithEnDashSeparator() {
        let text = """
        Which?

        1) Simple – easy to implement
        2) Complex – harder but thorough
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertEqual(result?.options[0].label, "Simple")
        XCTAssertEqual(result?.options[0].description, "easy to implement")
    }

    func testOptionWithColonSeparator() {
        let text = """
        Which?

        1) Simple: easy path
        2) Complex: hard path
        """
        let result = assertMultiOption(text, expectedCount: 2)
        XCTAssertEqual(result?.options[0].label, "Simple")
        XCTAssertEqual(result?.options[0].description, "easy path")
    }

    // MARK: - Protocol conformance

    func testAsyncProtocolPathNeverReturnsNil() async {
        // The heuristic is the end of the fallback chain — it always answers.
        let viaProtocol: any ResponseQuestionClassifying = classifier
        let result = await viaProtocol.classify("Just a statement.")
        XCTAssertEqual(result, .noQuestion)
    }
}
