import Foundation

/// Keeps agent-provided text useful for speech without allowing a long prompt, path,
/// or command to monopolize the audio channel. The original request remains unchanged.
enum SpokenText {
    static func condensed(
        _ text: String,
        maxWords: Int,
        maxCharacters: Int
    ) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }

        let words = collapsed.split(separator: " ", omittingEmptySubsequences: true)
        var result = words.prefix(maxWords).joined(separator: " ")
        var truncated = words.count > maxWords

        if result.count > maxCharacters {
            let limit = result.index(result.startIndex, offsetBy: maxCharacters)
            result = String(result[..<limit])
            if let lastSpace = result.lastIndex(of: " ") {
                result = String(result[..<lastSpace])
            }
            truncated = true
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated ? result + "…" : result
    }

    static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".?!…".contains(last) ? text : text + "."
    }
}
