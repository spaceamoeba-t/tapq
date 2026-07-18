import Foundation
import TapQWireProtocol

/// Renders a Claude Code tool call into a short spoken `summary` and a fuller `detail`.
/// This is an agent-specific seam: the broker stays agnostic and only sees the strings.
public enum ToolSummary {
    /// Keep spoken summaries to a handful of words; the full text waits behind "details".
    private static let summaryWordLimit = 6
    private static let summaryCharacterLimit = 64

    public static func render(toolName: String, input: [String: JSONValue]) -> (summary: String, detail: String) {
        switch toolName {
        case "Bash":
            let command = input["command"]?.stringValue ?? ""
            let speakable = clean(command)
            return ("run \(shorten(speakable))", "Run the command: \(speakable)")

        case "Write":
            let path = input["file_path"]?.stringValue ?? ""
            return ("create the file \(basename(path))", "Create the file at \(path)")

        case "Edit", "MultiEdit":
            let path = input["file_path"]?.stringValue ?? ""
            return ("edit the file \(basename(path))", "Edit the file at \(path)")

        case "NotebookEdit":
            let path = input["notebook_path"]?.stringValue ?? input["file_path"]?.stringValue ?? ""
            return ("edit the notebook \(basename(path))", "Edit the notebook at \(path)")

        default:
            return ("use the \(toolName) tool", compactJSON(input))
        }
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: "; ")
            .trimmingCharacters(in: .whitespaces)
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

    private static func basename(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func compactJSON(_ input: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(input),
              let string = String(data: data, encoding: .utf8) else {
            return "no details available"
        }
        return string
    }
}
