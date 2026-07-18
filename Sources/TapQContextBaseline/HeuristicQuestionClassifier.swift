import Foundation
import TapQContracts

/// Zero-latency fallback classifier: detects structured option lists (numbered,
/// lettered, or bold) near a question mark. It deliberately cannot detect yes/no
/// prose questions — regexes can't do that reliably, and the product bias is toward
/// false negatives (miss a question, the user types) over false positives (wrongly
/// block Claude). Yes/no detection is the Foundation Models classifier's job.
public struct HeuristicQuestionClassifier: ResponseQuestionClassifying {
    public init() {}

    public func classify(_ text: String) async -> ResponseQuestionClassification? {
        classifySync(text)
    }

    func classifySync(_ text: String) -> ResponseQuestionClassification {
        guard !text.isEmpty, text.contains("?") else { return .noQuestion }
        if let r = extractNumberedOptions(from: text) { return r }
        if let r = extractLetteredOptions(from: text) { return r }
        if let r = extractBoldOptions(from: text) { return r }
        return .noQuestion
    }

    // MARK: - Extraction patterns

    func extractNumberedOptions(from text: String) -> ResponseQuestionClassification? {
        let regex = try! NSRegularExpression(pattern: #"(?m)^\s*\d+\s*[.):\]]\s+(.+?)\s*$"#)
        return extractWithSingleCapture(from: text, regex: regex)
    }

    func extractLetteredOptions(from text: String) -> ResponseQuestionClassification? {
        let regex = try! NSRegularExpression(pattern: #"(?m)^\s*([A-Za-z])\s*[.):\]]\s+(.+?)\s*$"#)
        let matches = allMatches(regex, in: text)
        guard matches.count >= 2 else { return nil }
        guard capture(1, of: matches[0], in: text)?.lowercased() == "a" else { return nil }
        let options = matches.compactMap { capture(2, of: $0, in: text).map { parseOption($0) } }
        guard let firstRange = Range(matches[0].range, in: text) else { return nil }
        return buildIfValid(options: options, text: text, firstIndex: firstRange.lowerBound)
    }

    func extractBoldOptions(from text: String) -> ResponseQuestionClassification? {
        let regex = try! NSRegularExpression(
            pattern: #"(?m)^\s*[-•*]*\s*\*\*(.+?)\*\*\s*[-–—:]\s*(.+?)\s*$"#)
        let matches = allMatches(regex, in: text)
        guard matches.count >= 2 else { return nil }
        let options = matches.compactMap { m -> SelectionOption? in
            guard let label = capture(1, of: m, in: text),
                  let desc = capture(2, of: m, in: text) else { return nil }
            return SelectionOption(label: label, description: desc)
        }
        guard let firstRange = Range(matches[0].range, in: text) else { return nil }
        return buildIfValid(options: options, text: text, firstIndex: firstRange.lowerBound)
    }

    // MARK: - Shared helpers

    private func extractWithSingleCapture(
        from text: String, regex: NSRegularExpression
    ) -> ResponseQuestionClassification? {
        let matches = allMatches(regex, in: text)
        guard matches.count >= 2 else { return nil }
        let options = matches.compactMap { capture(1, of: $0, in: text).map { parseOption($0) } }
        guard let firstRange = Range(matches[0].range, in: text) else { return nil }
        return buildIfValid(options: options, text: text, firstIndex: firstRange.lowerBound)
    }

    private func buildIfValid(
        options: [SelectionOption], text: String, firstIndex: String.Index
    ) -> ResponseQuestionClassification? {
        guard options.count >= 2 else { return nil }
        guard !options.allSatisfy({ looksLikePath($0.label) }) else { return nil }
        guard let question = findQuestion(in: text, optionStart: firstIndex) else { return nil }
        return .multiOption(question: question, options: options)
    }

    func parseOption(_ raw: String) -> SelectionOption {
        for sep in [" - ", " – ", " — ", ": "] {
            if let r = raw.range(of: sep) {
                let label = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let desc = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { return SelectionOption(label: label, description: desc) }
            }
        }
        return SelectionOption(
            label: raw.replacingOccurrences(of: "**", with: "")
                      .trimmingCharacters(in: .whitespaces),
            description: "")
    }

    /// A question mark must appear within 2 paragraphs of the options — before them,
    /// or after them. This is the proximity filter that rejects lists far from any
    /// question.
    func findQuestion(in text: String, optionStart: String.Index) -> String? {
        let before = String(text[..<optionStart])
        let after = String(text[optionStart...])

        let beforeParagraphs = before.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let q = beforeParagraphs.suffix(2).last(where: { $0.contains("?") }) {
            return extractSentence(from: q)
        }

        let afterParagraphs = after.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Index 0 is the options block itself (a trailing question can be glued to it
        // with no blank line); 1–2 are the two paragraphs after the options.
        if let q = afterParagraphs.prefix(3).first(where: { $0.contains("?") }) {
            return extractSentence(from: q)
        }

        return nil
    }

    private func extractSentence(from paragraph: String) -> String {
        guard let qMark = paragraph.lastIndex(of: "?") else { return paragraph }
        let upToQ = paragraph[...qMark]
        if let start = upToQ.range(of: ". ", options: .backwards)?.upperBound {
            return String(upToQ[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(upToQ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikePath(_ label: String) -> Bool {
        if label.contains("/") { return true }
        let parts = label.split(separator: ".")
        guard parts.count >= 2, let ext = parts.last else { return false }
        return Self.pathExtensions.contains(String(ext).lowercased())
    }

    private func allMatches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func capture(_ group: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private static let pathExtensions: Set<String> = [
        "swift", "tsx", "ts", "js", "jsx", "css", "txt", "md", "json",
        "py", "go", "rs", "rb", "java", "kt", "yml", "yaml", "toml",
        "html", "xml", "sql", "sh", "h", "c", "cpp", "m", "plist",
    ]
}
