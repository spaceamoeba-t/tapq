import Foundation
import TapQContracts

/// What a classifier found in a coding assistant's final text reply.
///
/// The case is deliberately named `noQuestion` (not `none`): several call sites return
/// `ResponseQuestionClassification?`, where a bare `.none` would silently resolve to
/// `Optional.none` — a different meaning ("classifier can't answer") entirely.
public enum ResponseQuestionClassification: Equatable, Sendable {
    /// The reply doesn't ask the user anything answerable hands-free.
    case noQuestion
    /// The reply offers 2+ alternatives and asks the user to pick one.
    case multiOption(question: String, options: [SelectionOption])
    /// The reply asks a single question answerable with yes or no.
    case yesNo(question: String)
}

/// A strategy that reads a reply and extracts its question, if any.
///
/// Returning `nil` means "this classifier cannot answer" (model unavailable, error,
/// timeout) and the caller may fall back to another classifier. Returning
/// `.noQuestion` is an authoritative "there is nothing to ask".
public protocol ResponseQuestionClassifying: Sendable {
    func classify(_ text: String) async -> ResponseQuestionClassification?
}

/// The final-response question classifier requested for a runtime instance.
public enum QuestionClassifierProvider: String, CaseIterable, Equatable, Sendable {
    /// Prefer Apple's on-device model when available, otherwise use local heuristics.
    case auto
    /// Require Apple's on-device Foundation Models framework.
    case apple
    /// Use Anthropic Claude Haiku, with local heuristics as its runtime fallback.
    case anthropic
    /// Use OpenAI GPT-5.6 Luna, with local heuristics as its runtime fallback.
    case openai
    /// Use only deterministic structured-question heuristics.
    case local
}

/// A startup configuration error for an explicitly requested classifier provider.
public enum QuestionClassifierConfigurationError: Error, LocalizedError, Equatable {
    case missingAnthropicAPIKey
    case missingOpenAIAPIKey
    case appleFoundationModelUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingAnthropicAPIKey:
            return "Anthropic question classification requires ANTHROPIC_API_KEY "
                + "in the TapQ process environment."
        case .missingOpenAIAPIKey:
            return "OpenAI question classification requires OPENAI_API_KEY "
                + "in the TapQ process environment."
        case .appleFoundationModelUnavailable:
            return "Apple question classification was requested, but Foundation Models "
                + "are unavailable on this device. Select auto, anthropic, openai, or local instead."
        }
    }
}

/// Primary-then-fallback composition. The primary's `nil` ("can't answer") falls
/// through; its `.noQuestion` is authoritative and does NOT fall through — the
/// fallback regex must never resurrect a false positive the model rejected.
public struct QuestionClassifierChain: ResponseQuestionClassifying {
    let primary: (any ResponseQuestionClassifying)?
    let fallback: any ResponseQuestionClassifying

    public init(primary: (any ResponseQuestionClassifying)?,
                fallback: any ResponseQuestionClassifying) {
        self.primary = primary
        self.fallback = fallback
    }

    public func classify(_ text: String) async -> ResponseQuestionClassification? {
        if let primary, let result = await primary.classify(text) { return result }
        return await fallback.classify(text)
    }
}

/// The classifier implementation selected for a runtime instance.
public enum QuestionClassifierBackend: String, Equatable, Sendable {
    /// A caller-supplied classifier.
    case externalPrimary = "external_primary"
    /// Anthropic's Claude Haiku Messages API.
    case anthropicHaiku = "anthropic_haiku"
    /// OpenAI's GPT-5.6 Luna Responses API.
    case openAILuna = "openai_gpt_5_6_luna"
    /// Apple's on-device Foundation Models framework.
    case appleFoundationModel = "apple_foundation_model"
    /// The deterministic structured-option parser.
    case structuredHeuristic = "structured_heuristic"
}

/// A classifier together with the backend selected by the factory.
public struct QuestionClassifierSelection: Sendable {
    public let classifier: any ResponseQuestionClassifying
    public let backend: QuestionClassifierBackend

    public init(
        classifier: any ResponseQuestionClassifying,
        backend: QuestionClassifierBackend
    ) {
        self.classifier = classifier
        self.backend = backend
    }
}

/// Resolves runtime provider policy into a classifier chain backed by deterministic
/// heuristics. Hosts can still inject another primary classifier without changing the
/// default local policy.
public enum QuestionClassifierFactory {
    /// Resolves an explicit runtime policy into a classifier chain. Configuration
    /// failures throw at startup; provider failures during classification still return
    /// `nil` and fall through to deterministic local heuristics.
    public static func select(
        provider: QuestionClassifierProvider,
        anthropicAPIKey: String? = nil,
        openAIAPIKey: String? = nil,
        allowFoundationModel: Bool = true,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) throws -> QuestionClassifierSelection {
        switch provider {
        case .auto:
            return select(allowFoundationModel: allowFoundationModel)

        case .apple:
            let selection = select(allowFoundationModel: allowFoundationModel)
            guard selection.backend == .appleFoundationModel else {
                throw QuestionClassifierConfigurationError.appleFoundationModelUnavailable
            }
            return selection

        case .anthropic:
            guard let apiKey = anthropicAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                throw QuestionClassifierConfigurationError.missingAnthropicAPIKey
            }
            return QuestionClassifierSelection(
                classifier: QuestionClassifierChain(
                    primary: AnthropicHaikuQuestionClassifier(
                        apiKey: apiKey,
                        diagnosticSink: diagnosticSink
                    ),
                    fallback: HeuristicQuestionClassifier()
                ),
                backend: .anthropicHaiku
            )

        case .openai:
            guard let apiKey = openAIAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                throw QuestionClassifierConfigurationError.missingOpenAIAPIKey
            }
            return QuestionClassifierSelection(
                classifier: QuestionClassifierChain(
                    primary: OpenAILunaQuestionClassifier(
                        apiKey: apiKey,
                        diagnosticSink: diagnosticSink
                    ),
                    fallback: HeuristicQuestionClassifier()
                ),
                backend: .openAILuna
            )

        case .local:
            return select(allowFoundationModel: false)
        }
    }

    public static func select(
        primary: (any ResponseQuestionClassifying)? = nil,
        allowFoundationModel: Bool = true
    ) -> QuestionClassifierSelection {
        if let primary {
            return QuestionClassifierSelection(
                classifier: QuestionClassifierChain(
                    primary: primary,
                    fallback: HeuristicQuestionClassifier()
                ),
                backend: .externalPrimary
            )
        }

        #if canImport(FoundationModels)
        if allowFoundationModel,
           #available(macOS 26.0, iOS 26.0, *),
           FoundationModelClassifier.isSupported {
            return QuestionClassifierSelection(
                classifier: QuestionClassifierChain(
                    primary: FoundationModelClassifier(),
                    fallback: HeuristicQuestionClassifier()
                ),
                backend: .appleFoundationModel
            )
        }
        #endif

        return QuestionClassifierSelection(
            classifier: QuestionClassifierChain(
                primary: nil,
                fallback: HeuristicQuestionClassifier()
            ),
            backend: .structuredHeuristic
        )
    }

    public static func make(
        primary: (any ResponseQuestionClassifying)? = nil,
        allowFoundationModel: Bool = true
    ) -> any ResponseQuestionClassifying {
        select(
            primary: primary,
            allowFoundationModel: allowFoundationModel
        ).classifier
    }
}
