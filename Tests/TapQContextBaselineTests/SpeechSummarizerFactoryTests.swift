import XCTest
@testable import TapQContextBaseline

final class SpeechSummarizerFactoryTests: XCTestCase {
    struct StubSummarizer: SpokenSummarizing {
        let result: SpokenSummary?
        func summarize(_ text: String) async -> SpokenSummary? { result }
    }

    // MARK: - Chain

    func testPrimaryAnswerWins() async {
        let chain = SpokenSummarizerChain(
            primary: StubSummarizer(result: SpokenSummary(sentence: "Primary.", detail: "P")),
            fallback: StubSummarizer(result: SpokenSummary(sentence: "Fallback.", detail: "F")))
        let result = await chain.summarize("Some final reply.")
        XCTAssertEqual(result?.sentence, "Primary.")
    }

    func testPrimaryNilFallsBack() async {
        // Unlike the classifier, a summarizer has no authoritative "nothing to say":
        // nil always means "can't answer", so the deterministic reduction takes over.
        let chain = SpokenSummarizerChain(
            primary: StubSummarizer(result: nil),
            fallback: HeuristicSpokenSummarizer())
        let result = await chain.summarize("Rebuilt the bundle and reinstalled the hook.")
        XCTAssertEqual(result?.sentence, "Rebuilt the bundle and reinstalled the hook.")
    }

    func testAbsentPrimaryUsesFallback() async {
        let chain = SpokenSummarizerChain(
            primary: nil,
            fallback: StubSummarizer(result: SpokenSummary(sentence: "Fallback.", detail: "")))
        let result = await chain.summarize("anything")
        XCTAssertEqual(result?.sentence, "Fallback.")
    }

    func testChainFailsOpenWhenNothingCanSummarize() async {
        let chain = SpokenSummarizerChain(
            primary: StubSummarizer(result: nil),
            fallback: HeuristicSpokenSummarizer())
        let result = await chain.summarize("   ")
        XCTAssertNil(result)
    }

    // MARK: - Factory selection

    func testFactoryProducesAWorkingChain() async {
        // allowFoundationModel: false keeps this hermetic — constructing
        // FoundationModelSummarizer calls prewarm() and touches on-device model
        // state, which must never happen in an xctest host even on capable
        // hardware. The heuristic fallback still guarantees a non-nil result.
        let summarizer = SpeechSummarizerFactory.make(allowFoundationModel: false)
        let result = await summarizer?.summarize("Landed the change.")
        XCTAssertEqual(result?.sentence, "Landed the change.")
    }

    func testFactoryReportsHeuristicWhenFoundationModelIsDisabled() {
        let selection = SpeechSummarizerFactory.select(allowFoundationModel: false)
        XCTAssertEqual(selection.backend, .heuristic)
        XCTAssertNotNil(selection.summarizer)
    }

    func testFactoryReportsExternalPrimaryWithoutTouchingFoundationModel() async {
        let selection = SpeechSummarizerFactory.select(
            primary: StubSummarizer(result: SpokenSummary(sentence: "Injected.", detail: "")),
            allowFoundationModel: false
        )

        XCTAssertEqual(selection.backend, .externalPrimary)
        let result = await selection.summarizer?.summarize("Anything at all.")
        XCTAssertEqual(result?.sentence, "Injected.")
    }

    func testAutomaticProviderFallsBackToHeuristicWhenFoundationModelIsUnavailable() throws {
        let selection = try SpeechSummarizerFactory.select(
            provider: .auto,
            anthropicAPIKey: "inherited-but-not-enabled",
            openAIAPIKey: "also-inherited-but-not-enabled",
            allowFoundationModel: false
        )

        XCTAssertEqual(selection.backend, .heuristic)
    }

    func testHeuristicProviderAlwaysUsesTheLocalReduction() throws {
        let selection = try SpeechSummarizerFactory.select(
            provider: .heuristic,
            anthropicAPIKey: "inherited-but-not-enabled"
        )

        XCTAssertEqual(selection.backend, .heuristic)
    }

    func testOffProviderSelectsNoSummarizer() throws {
        let selection = try SpeechSummarizerFactory.select(
            provider: .off,
            anthropicAPIKey: "inherited-but-not-enabled",
            openAIAPIKey: "also-inherited-but-not-enabled"
        )

        XCTAssertEqual(selection.backend, .disabled)
        XCTAssertNil(selection.summarizer, "off must restore the pre-summary spoken behavior")
    }

    func testAnthropicProviderRequiresNonemptyAPIKey() {
        for key in [nil, "", "   "] as [String?] {
            XCTAssertThrowsError(try SpeechSummarizerFactory.select(
                provider: .anthropic,
                anthropicAPIKey: key,
                allowFoundationModel: false
            )) { error in
                XCTAssertEqual(
                    error as? SpeechSummarizerConfigurationError,
                    .missingAnthropicAPIKey
                )
            }
        }
    }

    func testAnthropicProviderOverridesFoundationModel() throws {
        let selection = try SpeechSummarizerFactory.select(
            provider: .anthropic,
            anthropicAPIKey: " test-key ",
            allowFoundationModel: false
        )

        XCTAssertEqual(selection.backend, .anthropicHaiku)
    }

    func testOpenAIProviderRequiresNonemptyAPIKey() {
        for key in [nil, "", "   "] as [String?] {
            XCTAssertThrowsError(try SpeechSummarizerFactory.select(
                provider: .openai,
                openAIAPIKey: key,
                allowFoundationModel: false
            )) { error in
                XCTAssertEqual(
                    error as? SpeechSummarizerConfigurationError,
                    .missingOpenAIAPIKey
                )
            }
        }
    }

    func testOpenAIProviderSelectsLuna() throws {
        let selection = try SpeechSummarizerFactory.select(
            provider: .openai,
            openAIAPIKey: " test-key ",
            allowFoundationModel: false
        )

        XCTAssertEqual(selection.backend, .openAILuna)
    }

    func testAppleProviderFailsWhenFoundationModelIsUnavailable() {
        XCTAssertThrowsError(try SpeechSummarizerFactory.select(
            provider: .apple,
            anthropicAPIKey: nil,
            allowFoundationModel: false
        )) { error in
            XCTAssertEqual(
                error as? SpeechSummarizerConfigurationError,
                .appleFoundationModelUnavailable
            )
        }
    }

    func testProviderNamesMatchTheDocumentedFlagValues() {
        XCTAssertEqual(
            Set(SpeechSummarizerProvider.allCases.map(\.rawValue)),
            ["auto", "apple", "anthropic", "openai", "heuristic", "off"]
        )
    }
}
