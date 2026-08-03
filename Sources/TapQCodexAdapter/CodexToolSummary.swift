import Foundation
import TapQWireProtocol

/// Renders Codex tool calls into the short and detailed presentation strings consumed by
/// TapQ's agent-neutral broker. Codex-specific tool names and argument shapes stay here.
public enum CodexToolSummary {
    private static let summaryWordLimit = 6
    private static let summaryCharacterLimit = 64
    private static let mcpDetailWordLimit = 18
    private static let mcpDetailCharacterLimit = 160

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

        case let name where name.hasPrefix("mcp__"):
            return mcpPresentation(toolName: name)

        default:
            let fallback = compactJSON(input)
            return (
                "use the \(toolName.isEmpty ? "requested" : toolName) tool",
                detail(description: input["description"]?.stringValue, fallback: fallback)
            )
        }
    }

    /// MCP arguments are an open-ended third-party schema and may contain credentials,
    /// private paths, message bodies, or other content. Presentation therefore derives
    /// exclusively from Codex's canonical `mcp__<server>__<tool>` name and never from
    /// argument values.
    private static func mcpPresentation(
        toolName: String
    ) -> (summary: String, detail: String) {
        let prefix = "mcp__"
        let remainder = toolName.dropFirst(prefix.count)
        guard let separator = remainder.range(of: "__") else {
            return ("use an MCP tool", "Use an MCP tool")
        }

        let server = humanizeMCPIdentifier(remainder[..<separator.lowerBound])
        let operation = humanizeMCPIdentifier(remainder[separator.upperBound...])
        guard !server.isEmpty, !operation.isEmpty else {
            return ("use an MCP tool", "Use an MCP tool")
        }

        return (
            boundedMCPText(
                "use \(operation) from \(server)",
                wordLimit: summaryWordLimit,
                characterLimit: summaryCharacterLimit
            ),
            boundedMCPText(
                "Use \(operation) from the \(server) MCP server",
                wordLimit: mcpDetailWordLimit,
                characterLimit: mcpDetailCharacterLimit
            )
        )
    }

    private static func humanizeMCPIdentifier(_ identifier: Substring) -> String {
        identifier
            .map { character in
                character.isLetter || character.isNumber ? String(character) : " "
            }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func boundedMCPText(
        _ text: String,
        wordLimit: Int,
        characterLimit: Int
    ) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        var result = words.prefix(wordLimit).joined(separator: " ")
        var truncated = words.count > wordLimit
        if result.count > characterLimit {
            truncated = true
        }
        guard truncated else { return result }

        let contentLimit = max(0, characterLimit - 1)
        if result.count > contentLimit {
            let limit = result.index(result.startIndex, offsetBy: contentLimit)
            result = String(result[..<limit])
            if let lastSpace = result.lastIndex(of: " ") {
                result = String(result[..<lastSpace])
            }
        }
        return result + "…"
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
