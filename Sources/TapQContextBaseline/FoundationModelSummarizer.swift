#if canImport(FoundationModels)
import Foundation
import FoundationModels
import TapQContracts

/// On-device spoken summarization via Apple's Foundation Models framework.
///
/// Model unavailability, generation errors, and timeouts return `nil`, allowing the
/// summarizer chain to fail open through its deterministic fallback. No reply text is
/// sent to a network service. The generated fields are still truncated locally: the
/// length guidance below is a hint, ``SpokenSummary`` is the enforcement.
@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelSummarizer: SpokenSummarizing {
    static let instructions = """
        You read the final reply a coding assistant sent to its user and write what a \
        wearable assistant should say out loud about it. Produce:
        - sentence: one spoken-friendly sentence, at most 120 characters, saying what \
        the assistant did or is asking about. No markdown, no code, no file paths.
        - detail: at most 320 characters of extra spoken context the user can ask for, \
        covering specifics the sentence left out. Empty when the sentence says everything.
        Never invent work the reply does not describe, never ask the user a question, \
        and never tell the user to approve or run anything. Never read out a URL or a \
        link: say where it points in a few words — the site, the repository, the page's \
        title — and no more.
        """

    @Generable
    struct Summary {
        @Guide(description: "One spoken-friendly sentence, at most 120 characters")
        var sentence: String
        @Guide(description: "At most 320 characters of extra spoken context. Empty when unneeded.")
        var detail: String
    }

    static let timeout: TimeInterval = 5

    public static var isSupported: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public init() {
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    public func summarize(_ text: String) async -> SpokenSummary? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard Self.isSupported else { return nil }

        return await withTaskGroup(of: SpokenSummary?.self) { group in
            group.addTask { await Self.generate(text) }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func generate(_ text: String) async -> SpokenSummary? {
        let session = LanguageModelSession(instructions: instructions)
        guard let response = try? await session.respond(
            to: "Summarize this reply for speech:\n\n\(text)",
            generating: Summary.self,
            options: GenerationOptions(sampling: .greedy)
        ) else { return nil }
        return interpret(response.content)
    }

    static func interpret(_ summary: Summary) -> SpokenSummary? {
        SpokenSummary.make(sentence: summary.sentence, detail: summary.detail)
    }
}
#endif
