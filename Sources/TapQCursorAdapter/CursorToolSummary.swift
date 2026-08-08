import Foundation
import TapQWireProtocol

/// Renders Cursor tool calls into the short and detailed presentation strings consumed by
/// TapQ's agent-neutral broker. Cursor-specific tool names and argument shapes stay here.
///
/// Cursor documents a stable name for the tool *type* (`Shell`, `Write`, `Delete`, …) but
/// not the argument object each type carries: `preToolUse` declares `tool_input` as an
/// open `{}`. Presentation therefore names the action from the tool type, resolves a file
/// path only from keys Cursor's editor tools are observed to use, and never falls back to
/// dumping the argument object — a Cursor write payload can contain the entire new file
/// body, which must not be spoken.
///
/// Source: https://cursor.com/docs/agent/hooks (hook input/output reference).
public enum CursorToolSummary {
    /// Keep spoken summaries to a handful of words; the full text waits behind "details".
    private static let summaryWordLimit = 6
    private static let summaryCharacterLimit = 64

    /// Keys a Cursor file tool may use for its primary path, most canonical first.
    /// `file_path` also matches the key the on-device reasoner reads for `Write`.
    static let filePathKeys = ["file_path", "path", "target_file"]

    public static func render(
        toolName: String,
        input: [String: JSONValue]
    ) -> (summary: String, detail: String) {
        switch toolName {
        case CursorTool.shell:
            let command = clean(input["command"]?.stringValue ?? "")
            guard !command.isEmpty else { return ("run a command", "Run a command") }
            return ("run \(shorten(command))", "Run the command: \(command)")

        case CursorTool.write:
            guard let path = filePath(in: input) else {
                return ("write a file", "Write a file")
            }
            return ("write the file \(basename(path))", "Write the file at \(path)")

        case CursorTool.delete:
            guard let path = filePath(in: input) else {
                return ("delete a file", "Delete a file")
            }
            return ("delete the file \(basename(path))", "Delete the file at \(path)")

        default:
            // Unreached by the installed slice. Kept value-free because an unmanaged
            // Cursor tool's argument object is an undocumented schema.
            let name = toolName.isEmpty ? "requested" : toolName
            return ("use the \(name) tool", "Use the \(name) tool")
        }
    }

    static func filePath(in input: [String: JSONValue]) -> String? {
        for key in filePathKeys {
            if let value = nonblank(input[key]?.stringValue) { return clean(value) }
        }
        return nil
    }

    private static func nonblank(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
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

    private static func basename(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// The Cursor tool-type names TapQ recognizes.
///
/// These are Cursor's own `preToolUse` matcher values, so what TapQ reports on the wire
/// and in diagnostics is what Cursor calls the tool. `beforeShellExecution` carries no
/// tool name of its own; the shim labels it `Shell`, the type Cursor uses for the same
/// operation in `preToolUse`.
public enum CursorTool {
    public static let shell = "Shell"
    public static let write = "Write"
    public static let delete = "Delete"
}
