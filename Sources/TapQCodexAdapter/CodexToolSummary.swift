import Foundation
import TapQWireProtocol

/// Renders Codex tool calls into the short and detailed presentation strings consumed by
/// TapQ's agent-neutral broker. Codex-specific tool names and argument shapes stay here.
public enum CodexToolSummary {
    private static let summaryWordLimit = 6
    private static let summaryCharacterLimit = 64

    public static func render(
        toolName: String,
        input: [String: JSONValue]
    ) -> (summary: String, detail: String) {
        switch toolName {
        case "Bash":
            let command = clean(input["command"]?.stringValue ?? "")
            let summary = command.isEmpty ? "run a command" : "run \(shorten(command))"
            return (summary, detail(
                description: input["description"]?.stringValue,
                fallback: command.isEmpty ? "Run a command" : "Run the command: \(command)"
            ))

        case "apply_patch":
            let patch = clean(input["command"]?.stringValue ?? "")
            let fallback = patch.isEmpty ? "Apply a code patch" : "Apply this code patch: \(patch)"
            return ("apply a code patch", detail(
                description: input["description"]?.stringValue,
                fallback: fallback
            ))

        default:
            let fallback = compactJSON(input)
            return (
                "use the \(toolName.isEmpty ? "requested" : toolName) tool",
                detail(description: input["description"]?.stringValue, fallback: fallback)
            )
        }
    }

    private static func detail(description: String?, fallback: String) -> String {
        let cleaned = clean(description ?? "")
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .joined(separator: "; ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shorten(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var result = words.prefix(summaryWordLimit).joined(separator: " ")
        var truncated = words.count > summaryWordLimit
        if result.count > summaryCharacterLimit {
            let limit = result.index(result.startIndex, offsetBy: summaryCharacterLimit)
            result = String(result[..<limit])
            if let lastSpace = result.lastIndex(of: " ") {
                result = String(result[..<lastSpace])
            }
            truncated = true
        }
        return truncated ? result + "…" : result
    }

    private static func compactJSON(_ input: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(input),
              let string = String(data: data, encoding: .utf8) else {
            return "no details available"
        }
        return string
    }
}
