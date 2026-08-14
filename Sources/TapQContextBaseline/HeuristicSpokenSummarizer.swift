import Foundation
import TapQContracts

/// Zero-latency fallback summarizer: strips the markdown and code an agent writes for
/// a screen, then speaks the opening of what is left.
///
/// It has no idea what the reply *means* — it only removes what is unspeakable and
/// obeys the RA2 caps. That is deliberate: this is the summarizer of last resort, so
/// it must be deterministic, offline, and incapable of inventing content that was
/// never in the text. It succeeds on any text with a speakable character in it.
public struct HeuristicSpokenSummarizer: SpokenSummarizing {
    public init() {}

    public func summarize(_ text: String) async -> SpokenSummary? {
        summarizeSync(text)
    }

    func summarizeSync(_ text: String) -> SpokenSummary? {
        let speakable = Self.speakableText(from: text)
        guard !speakable.isEmpty else { return nil }
        return SpokenSummary.make(sentence: speakable, detail: speakable)
    }

    // MARK: - Cleaning

    /// Removes fenced code, inline code, links, and line-level markdown, then joins the
    /// surviving lines into prose. Headings and list items that lack end punctuation get
    /// a period so the sentence splitter does not glue two bullets into one utterance.
    static func speakableText(from text: String) -> String {
        var stripped = text
        for pattern in blockPatterns {
            stripped = replacing(pattern, in: stripped, with: "")
        }
        for (pattern, template) in inlinePatterns {
            stripped = replacing(pattern, in: stripped, with: template)
        }
        stripped = stripped.replacingOccurrences(of: "```", with: "")
        stripped = stripped.replacingOccurrences(of: "**", with: "")
        stripped = stripped.replacingOccurrences(of: "__", with: "")

        let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
        var sentencesOut: [String] = []
        for line in lines {
            let raw = String(line)
            let wasListed = isListItem(raw) || isHeading(raw)
            var cleaned = raw
            for (pattern, template) in linePatterns {
                cleaned = replacing(pattern, in: cleaned, with: template)
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }
            if wasListed, let last = cleaned.last, !".!?:;".contains(last) {
                cleaned += "."
            }
            sentencesOut.append(cleaned)
        }

        return SpokenSummaryText.normalized(sentencesOut.joined(separator: " "))
    }

    private static func isListItem(_ line: String) -> Bool {
        matches(#"^\s*([-*+•]|\d+\s*[.):\]])\s+"#, line)
    }

    private static func isHeading(_ line: String) -> Bool {
        matches(#"^\s{0,3}#{1,6}\s+"#, line)
    }

    // MARK: - Regex helpers

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replacing(
        _ pattern: String, in text: String, with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// Whole regions that are never spoken.
    private static let blockPatterns = [
        #"(?s)```.*?```"#,
        #"(?s)~~~.*?~~~"#,
    ]

    /// Inline markup reduced to the text a listener would hear.
    private static let inlinePatterns: [(String, String)] = [
        (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
        (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        (#"`([^`]*)`"#, "$1"),
    ]

    /// Line-leading markdown furniture.
    private static let linePatterns: [(String, String)] = [
        (#"^\s{0,3}#{1,6}\s+"#, ""),
        (#"^\s{0,3}>\s?"#, ""),
        (#"^\s*[-*+•]\s+"#, ""),
        (#"^\s*\d+\s*[.):\]]\s+"#, ""),
        (#"^\s*([-*_])\s*\1\s*\1[-*_\s]*$"#, ""),
    ]
}
