import XCTest
@testable import TapQContextBaseline
import TapQContracts

final class QuestionClassifierChainTests: XCTestCase {
    struct StubClassifier: ResponseQuestionClassifying {
        let result: ResponseQuestionClassification?
        func classify(_ text: String) async -> ResponseQuestionClassification? { result }
    }

    func testPrimaryAnswerWins() async {
        let chain = QuestionClassifierChain(
            primary: StubClassifier(result: .yesNo(question: "Apply the fix")),
            fallback: StubClassifier(result: .noQuestion))
        let result = await chain.classify("Should I apply the fix?")
        XCTAssertEqual(result, .yesNo(question: "Apply the fix"))
    }

    func testPrimaryNoQuestionIsAuthoritative() async {
        // .noQuestion is an answer, not a failure — the fallback must NOT get a chance
        // to re-introduce a false positive the smarter model already rejected.
        let chain = QuestionClassifierChain(
            primary: StubClassifier(result: .noQuestion),
            fallback: StubClassifier(result: .yesNo(question: "ghost")))
        let result = await chain.classify("statement")
        XCTAssertEqual(result, .noQuestion)
    }

    func testPrimaryNilFallsBack() async {
        let chain = QuestionClassifierChain(
            primary: StubClassifier(result: nil),
            fallback: StubClassifier(result: .multiOption(
                question: "Which?",
                options: [SelectionOption(label: "A", description: ""),
                          SelectionOption(label: "B", description: "")])))
        let result = await chain.classify("Which?\n1) A\n2) B")
        guard case .multiOption(let question, let options)? = result else {
            return XCTFail("expected fallback multiOption")
        }
        XCTAssertEqual(question, "Which?")
        XCTAssertEqual(options.count, 2)
    }

    func testAbsentPrimaryUsesFallback() async {
        let chain = QuestionClassifierChain(
            primary: nil,
            fallback: StubClassifier(result: .noQuestion))
        let result = await chain.classify("anything")
        XCTAssertEqual(result, .noQuestion)
    }

    func testFactoryProducesAWorkingChain() async {
        // allowFoundationModel: false keeps this hermetic — constructing
        // FoundationModelClassifier calls prewarm() and touches on-device model
        // state, which must never happen in an xctest host even on capable
        // hardware. The heuristic fallback still guarantees a non-nil result.
        let classifier = QuestionClassifierFactory.make(allowFoundationModel: false)
        let result = await classifier.classify("Just a statement, nothing to ask.")
        XCTAssertNotNil(result)
    }

    func testFactoryReportsHeuristicWhenFoundationModelIsDisabled() {
        let selection = QuestionClassifierFactory.select(allowFoundationModel: false)
        XCTAssertEqual(selection.backend, .structuredHeuristic)
    }

    func testFactoryReportsExternalPrimaryWithoutTouchingFoundationModel() async {
        let selection = QuestionClassifierFactory.select(
            primary: StubClassifier(result: .yesNo(question: "Proceed?")),
            allowFoundationModel: false
        )

        XCTAssertEqual(selection.backend, .externalPrimary)
        let result = await selection.classifier.classify("Should I proceed?")
        XCTAssertEqual(result, .yesNo(question: "Proceed?"))
    }

    func testAutomaticProviderFallsBackToHeuristicWhenFoundationModelIsUnavailable() throws {
        let selection = try QuestionClassifierFactory.select(
            provider: .auto,
            anthropicAPIKey: "inherited-but-not-enabled",
            openAIAPIKey: "also-inherited-but-not-enabled",
            allowFoundationModel: false
        )

        XCTAssertEqual(selection.backend, .structuredHeuristic)
    }

    func testLocalProviderAlwaysUsesHeuristic() throws {
        let selection = try QuestionClassifierFactory.select(
            provider: .local,
            anthropicAPIKey: "inherited-but-not-enabled"
        )

        XCTAssertEqual(selection.backend, .structuredHeuristic)
    }

    func testAnthropicProviderRequiresNonemptyAPIKey() {
        for key in [nil, "", "   "] as [String?] {
            XCTAssertThrowsError(try QuestionClassifierFactory.select(
                provider: .anthropic,
                anthropicAPIKey: key,
                allowFoundationModel: false
            )) { error in
                XCTAssertEqual(
                    error as? QuestionClassifierConfigurationError,
                    .missingAnthropicAPIKey
                )
            }
        }
    }

    func testAnthropicProviderOverridesFoundationModel() throws {
        let selection = try QuestionClassifierFactory.select(
            provider: .anthropic,
            anthropicAPIKey: " test-key ",
            allowFoundationModel: false
        )

        XCTAssertEqual(selection.backend, .anthropicHaiku)
    }

    func testOpenAIProviderRequiresNonemptyAPIKey() {
        for key in [nil, "", "   "] as [String?] {
            XCTAssertThrowsError(try QuestionClassifierFactory.select(
                provider: .openai,
                openAIAPIKey: key,
                allowFoundationModel: false
            )) { error in
                XCTAssertEqual(
                    error as? QuestionClassifierConfigurationError,
                    .missingOpenAIAPIKey
                )
            }
        }
    }

    func testOpenAIProviderSelectsLuna() throws {
        let selection = try QuestionClassifierFactory.select(
            provider: .openai,
            openAIAPIKey: " test-key ",
            allowFoundationModel: false
        )

        XCTAssertEqual(selection.backend, .openAILuna)
    }

    func testAppleProviderFailsWhenFoundationModelIsUnavailable() {
        XCTAssertThrowsError(try QuestionClassifierFactory.select(
            provider: .apple,
            anthropicAPIKey: nil,
            allowFoundationModel: false
        )) { error in
            XCTAssertEqual(
                error as? QuestionClassifierConfigurationError,
                .appleFoundationModelUnavailable
            )
        }
    }
}
