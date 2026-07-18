#if canImport(FoundationModels)
import Foundation
import FoundationModels
import TapQContracts

/// On-device question extraction via Apple's Foundation Models framework.
///
/// Model unavailability, generation errors, and timeouts return `nil`, allowing the
/// classifier chain to fail open through its deterministic fallback. No reply text is
/// sent to a network service.
@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelClassifier: ResponseQuestionClassifying {
    static let instructions = """
        You read the final reply a coding assistant sent to its user and decide whether \
        it is waiting on the user to answer a question. Classify the reply:
        - multi_option: it offers two or more distinct alternatives and asks the user to pick one.
        - yes_no: it asks a single question answerable with yes or no.
        - none: everything else (statements, rhetorical questions, and open-ended \
        questions with no offered alternatives).
        Summarize the question in at most 12 spoken-friendly words. For multi_option, \
        list each offered alternative in order with a label of at most 4 words and a \
        one-line description. Never invent alternatives the reply does not offer.
        """

    @Generable
    struct Extraction {
        @Guide(description: "One of: none, multi_option, yes_no")
        var kind: String
        @Guide(description: "The question, at most 12 spoken-friendly words. Empty when kind is none.")
        var question: String
        @Guide(description: "The offered alternatives in order. Empty unless kind is multi_option.")
        var options: [Option]

        @Generable
        struct Option {
            @Guide(description: "Short spoken label, at most 4 words")
            var label: String
            @Guide(description: "One short sentence describing this alternative")
            var description: String
        }
    }

    static let timeout: TimeInterval = 5

    public static var isSupported: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public init() {
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    public func classify(_ text: String) async -> ResponseQuestionClassification? {
        guard text.contains("?") else { return nil }
        guard Self.isSupported else { return nil }

        return await withTaskGroup(of: ResponseQuestionClassification?.self) { group in
            group.addTask { await Self.extract(text) }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func extract(_ text: String) async -> ResponseQuestionClassification? {
        let session = LanguageModelSession(instructions: instructions)
        guard let response = try? await session.respond(
            to: "Classify this reply:\n\n\(text)",
            generating: Extraction.self,
            options: GenerationOptions(sampling: .greedy)
        ) else { return nil }
        return interpret(response.content)
    }

    static func interpret(_ extraction: Extraction) -> ResponseQuestionClassification {
        let question = extraction.question.trimmingCharacters(in: .whitespacesAndNewlines)
        switch extraction.kind {
        case "multi_option":
            let options = extraction.options.prefix(6).map {
                SelectionOption(label: $0.label, description: $0.description)
            }
            guard options.count >= 2, !question.isEmpty else { return .noQuestion }
            return .multiOption(question: question, options: Array(options))
        case "yes_no":
            guard !question.isEmpty else { return .noQuestion }
            return .yesNo(question: question)
        default:
            return .noQuestion
        }
    }
}
#endif
