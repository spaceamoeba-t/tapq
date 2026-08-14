import Foundation
import TapQContracts

/// What TapQ says out loud about an agent's final text reply.
///
/// `sentence` is the one line spoken in the moment; `detail` is the longer text a
/// wearer hears after asking for details. Both fields are capped by deterministic
/// truncation in `init` — a summarizer backed by a model is never trusted to respect
/// a length instruction, so the caps hold even when the model ignores them.
public struct SpokenSummary: Equatable, Sendable {
    /// Spoken-sentence budget. One short sentence a wearer can absorb in one breath.
    public static let sentenceCharacterLimit = 120
    /// Follow-up budget for the "details" command.
    public static let detailCharacterLimit = 320

    /// A single spoken-friendly sentence, at most ``sentenceCharacterLimit`` characters.
    public let sentence: String
    /// Extra spoken context, at most ``detailCharacterLimit`` characters. May be empty.
    public let detail: String

    /// Normalizes whitespace and truncates both fields to their caps.
    ///
    /// The truncation is intentionally part of the only initializer: no code path,
    /// including a provider that returned an essay, can produce an over-cap summary.
    public init(sentence: String, detail: String) {
        self.sentence = SpokenSummaryText.cappedSentence(sentence)
        self.detail = SpokenSummaryText.cappedDetail(detail)
    }

    /// Builds a summary, or `nil` when nothing speakable survived normalization.
    ///
    /// Providers use this so an empty or whitespace-only model field fails open to the
    /// caller's existing behavior instead of scheduling a silent utterance.
    static func make(sentence: String, detail: String) -> SpokenSummary? {
        let summary = SpokenSummary(sentence: sentence, detail: detail)
        return summary.sentence.isEmpty ? nil : summary
    }
}

/// A strategy that condenses an agent's final reply into speech.
///
/// Returning `nil` means "this summarizer cannot answer" (model unavailable, error,
/// timeout, or nothing speakable in the text). Every caller must behave exactly as it
/// did before summaries existed when it receives `nil`.
public protocol SpokenSummarizing: Sendable {
    func summarize(_ text: String) async -> SpokenSummary?
}

/// The spoken-summary provider requested for a runtime instance.
public enum SpeechSummarizerProvider: String, CaseIterable, Equatable, Sendable {
    /// Prefer Apple's on-device model when available, otherwise use local heuristics.
    case auto
    /// Require Apple's on-device Foundation Models framework.
    case apple
    /// Use Anthropic Claude Haiku, with local heuristics as its runtime fallback.
    case anthropic
    /// Use OpenAI GPT-5.6 Luna, with local heuristics as its runtime fallback.
    case openai
    /// Use only the deterministic local text reduction.
    case heuristic
    /// Produce no summaries at all, restoring the pre-summary spoken behavior.
    case off
}

/// A startup configuration error for an explicitly requested summarizer provider.
public enum SpeechSummarizerConfigurationError: Error, LocalizedError, Equatable {
    case missingAnthropicAPIKey
    case missingOpenAIAPIKey
    case appleFoundationModelUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingAnthropicAPIKey:
            return "Anthropic speech summarization requires ANTHROPIC_API_KEY "
                + "in the TapQ process environment."
        case .missingOpenAIAPIKey:
            return "OpenAI speech summarization requires OPENAI_API_KEY "
                + "in the TapQ process environment."
        case .appleFoundationModelUnavailable:
            return "Apple speech summarization was requested, but Foundation Models "
                + "are unavailable on this device. Select auto, anthropic, openai, "
                + "heuristic, or off instead."
        }
    }
}

/// Primary-then-fallback composition. The primary's `nil` ("can't answer") falls
/// through to the deterministic local summarizer, so a cloud outage degrades to a
/// plainer sentence rather than to silence.
public struct SpokenSummarizerChain: SpokenSummarizing {
    let primary: (any SpokenSummarizing)?
    let fallback: any SpokenSummarizing

    public init(primary: (any SpokenSummarizing)?,
                fallback: any SpokenSummarizing) {
        self.primary = primary
        self.fallback = fallback
    }

    public func summarize(_ text: String) async -> SpokenSummary? {
        if let primary, let result = await primary.summarize(text) { return result }
        return await fallback.summarize(text)
    }
}

/// The summarizer implementation selected for a runtime instance.
public enum SpeechSummarizerBackend: String, Equatable, Sendable {
    /// A caller-supplied summarizer.
    case externalPrimary = "external_primary"
    /// Anthropic's Claude Haiku Messages API.
    case anthropicHaiku = "anthropic_haiku"
    /// OpenAI's GPT-5.6 Luna Responses API.
    case openAILuna = "openai_gpt_5_6_luna"
    /// Apple's on-device Foundation Models framework.
    case appleFoundationModel = "apple_foundation_model"
    /// The deterministic local text reduction.
    case heuristic = "heuristic"
    /// No summarizer: spoken behavior is exactly what it was before Rung A.
    case disabled = "disabled"
}

/// A summarizer together with the backend selected by the factory.
///
/// `summarizer` is `nil` only for ``SpeechSummarizerProvider/off``; callers hold an
/// optional summarizer anyway, so "disabled" needs no null-object stand-in.
public struct SpeechSummarizerSelection: Sendable {
    public let summarizer: (any SpokenSummarizing)?
    public let backend: SpeechSummarizerBackend

    public init(
        summarizer: (any SpokenSummarizing)?,
        backend: SpeechSummarizerBackend
    ) {
        self.summarizer = summarizer
        self.backend = backend
    }
}

/// Resolves runtime provider policy into a summarizer chain backed by a deterministic
/// local reduction. Hosts can still inject another primary summarizer without changing
/// the default local policy.
public enum SpeechSummarizerFactory {
    /// Resolves an explicit runtime policy into a summarizer chain. Configuration
    /// failures throw at startup; provider failures during summarization still return
    /// `nil` and fall through to the deterministic local reduction.
    public static func select(
        provider: SpeechSummarizerProvider,
        anthropicAPIKey: String? = nil,
        openAIAPIKey: String? = nil,
        allowFoundationModel: Bool = true,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) throws -> SpeechSummarizerSelection {
        switch provider {
        case .auto:
            return select(allowFoundationModel: allowFoundationModel)

        case .apple:
            let selection = select(allowFoundationModel: allowFoundationModel)
            guard selection.backend == .appleFoundationModel else {
                throw SpeechSummarizerConfigurationError.appleFoundationModelUnavailable
            }
            return selection

        case .anthropic:
            guard let apiKey = anthropicAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                throw SpeechSummarizerConfigurationError.missingAnthropicAPIKey
            }
            return SpeechSummarizerSelection(
                summarizer: SpokenSummarizerChain(
                    primary: AnthropicHaikuSummarizer(
                        apiKey: apiKey,
                        diagnosticSink: diagnosticSink
                    ),
                    fallback: HeuristicSpokenSummarizer()
                ),
                backend: .anthropicHaiku
            )

        case .openai:
            guard let apiKey = openAIAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                throw SpeechSummarizerConfigurationError.missingOpenAIAPIKey
            }
            return SpeechSummarizerSelection(
                summarizer: SpokenSummarizerChain(
                    primary: OpenAILunaSummarizer(
                        apiKey: apiKey,
                        diagnosticSink: diagnosticSink
                    ),
                    fallback: HeuristicSpokenSummarizer()
                ),
                backend: .openAILuna
            )

        case .heuristic:
            return select(allowFoundationModel: false)

        case .off:
            return SpeechSummarizerSelection(summarizer: nil, backend: .disabled)
        }
    }

    public static func select(
        primary: (any SpokenSummarizing)? = nil,
        allowFoundationModel: Bool = true
    ) -> SpeechSummarizerSelection {
        if let primary {
            return SpeechSummarizerSelection(
                summarizer: SpokenSummarizerChain(
                    primary: primary,
                    fallback: HeuristicSpokenSummarizer()
                ),
                backend: .externalPrimary
            )
        }

        #if canImport(FoundationModels)
        if allowFoundationModel,
           #available(macOS 26.0, iOS 26.0, *),
           FoundationModelSummarizer.isSupported {
            return SpeechSummarizerSelection(
                summarizer: SpokenSummarizerChain(
                    primary: FoundationModelSummarizer(),
                    fallback: HeuristicSpokenSummarizer()
                ),
                backend: .appleFoundationModel
            )
        }
        #endif

        return SpeechSummarizerSelection(
            summarizer: SpokenSummarizerChain(
                primary: nil,
                fallback: HeuristicSpokenSummarizer()
            ),
            backend: .heuristic
        )
    }

    public static func make(
        primary: (any SpokenSummarizing)? = nil,
        allowFoundationModel: Bool = true
    ) -> (any SpokenSummarizing)? {
        select(
            primary: primary,
            allowFoundationModel: allowFoundationModel
        ).summarizer
    }
}

/// The deterministic text reductions every summarizer shares.
///
/// These are the RA2 caps: whatever a provider returns is normalized, cut to one
/// sentence, and truncated on a word boundary here, never in the prompt.
enum SpokenSummaryText {
    /// Collapses every whitespace run — including newlines — into single spaces.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// One normalized sentence, truncated to ``SpokenSummary/sentenceCharacterLimit``.
    static func cappedSentence(_ text: String) -> String {
        truncated(
            firstSentence(of: normalized(text)),
            limit: SpokenSummary.sentenceCharacterLimit
        )
    }

    /// Normalized text truncated to ``SpokenSummary/detailCharacterLimit``, preferring
    /// to end on a sentence boundary so the wearer never hears a clipped clause.
    static func cappedDetail(_ text: String) -> String {
        let normalizedText = normalized(text)
        guard normalizedText.count > SpokenSummary.detailCharacterLimit else {
            return normalizedText
        }

        var kept = ""
        for sentence in sentences(of: normalizedText) {
            let candidate = kept.isEmpty ? sentence : kept + " " + sentence
            if candidate.count > SpokenSummary.detailCharacterLimit { break }
            kept = candidate
        }
        guard kept.isEmpty else { return kept }
        return truncated(normalizedText, limit: SpokenSummary.detailCharacterLimit)
    }

    /// Truncates on the last word boundary that fits, trimming dangling punctuation.
    /// A single word longer than `limit` is cut mid-word rather than dropped.
    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        guard let lastSpace = head.lastIndex(of: " ") else { return head }
        let clipped = String(head[..<lastSpace])
        return String(
            clipped.reversed()
                .drop(while: { $0.isWhitespace || Self.danglingPunctuation.contains($0) })
                .reversed()
        )
    }

    /// Splits normalized text on sentence terminators, skipping the terminators that
    /// end an abbreviation, an ordinal, or a bare list number.
    static func sentences(of normalizedText: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in normalizedText {
            current.append(character)
            guard terminators.contains(character) else { continue }
            guard character != "." || !endsWithNonTerminalAbbreviation(current) else { continue }
            let sentence = current.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { result.append(sentence) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func firstSentence(of normalizedText: String) -> String {
        sentences(of: normalizedText).first ?? ""
    }

    /// True when the trailing token before a period is something like `e.g.`, `1.`, or
    /// `A.` — a period that does not end a sentence.
    private static func endsWithNonTerminalAbbreviation(_ text: String) -> Bool {
        let token = text
            .split(whereSeparator: { $0.isWhitespace })
            .last
            .map(String.init) ?? ""
        let word = String(token.dropLast()) // the period itself
        if word.isEmpty { return true }
        if abbreviations.contains(word.lowercased()) { return true }
        if word.count == 1, let only = word.first, only.isLetter || only.isNumber { return true }
        return word.allSatisfy { $0.isNumber }
    }

    private static let terminators: Set<Character> = [".", "!", "?"]
    private static let danglingPunctuation: Set<Character> = [",", ";", ":", "-", "–", "—"]
    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "cf", "approx", "no", "fig",
        "dr", "mr", "mrs", "ms", "prof", "st", "jr", "sr",
    ]
}
