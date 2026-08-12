import Foundation
import TapQWireProtocol

/// Renders OpenCode permission requests into the short and detailed presentation strings
/// consumed by TapQ's agent-neutral broker. OpenCode-specific permission kinds and
/// metadata shapes stay here.
///
/// A `permission.asked` request carries no human-readable title — OpenCode's own prompt is
/// rendered from the permission kind plus that kind's `metadata` object. TapQ therefore
/// speaks from the same two inputs, but reads only the scalar metadata keys documented for
/// the kinds it supports. `metadata` is `Record<string, unknown>` filled in by whichever
/// tool raised the request, so it can carry file contents, diffs, request bodies, or
/// credentials; it is never serialized wholesale into speech.
///
/// Permission kinds and their metadata come from the request schema and the tools that
/// publish it:
/// - https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/v1/permission.ts
/// - https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/tool/webfetch.ts
public enum OpenCodeToolSummary {
    private static let summaryWordLimit = 6
    private static let summaryCharacterLimit = 64
    private static let detailCharacterLimit = 240

    /// Permission kinds TapQ renders with kind-specific wording. Every other kind — and
    /// every kind OpenCode adds later — falls back to a neutral phrase built from the kind
    /// name alone, so a new metadata schema can never leak into speech by default.
    public enum Kind: String, Sendable {
        case bash
        case edit
        case webfetch
    }

    public static func render(
        permission: String,
        metadata: [String: JSONValue]
    ) -> (summary: String, detail: String) {
        switch Kind(rawValue: permission) {
        case .bash:
            let command = clean(scalar(metadata["command"]) ?? "")
            guard !command.isEmpty else {
                return ("run a command", "Run a command")
            }
            return (
                "run \(shorten(command))",
                bounded("Run the command: \(command)", characterLimit: detailCharacterLimit)
            )

        case .edit:
            let path = clean(scalar(metadata["filePath"]) ?? scalar(metadata["path"]) ?? "")
            guard !path.isEmpty else {
                return ("edit a file", "Edit a file")
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return (
                "edit \(shorten(name.isEmpty ? path : name))",
                bounded("Edit the file: \(path)", characterLimit: detailCharacterLimit)
            )

        case .webfetch:
            // A URL can carry tokens in its path or query, so only the host is spoken. The
            // complete value stays in the broker request context, as MCP arguments do for
            // the Codex adapter.
            let host = clean(host(of: scalar(metadata["url"]) ?? "") ?? "")
            guard !host.isEmpty else {
                return ("fetch a web page", "Fetch a web page")
            }
            return ("fetch a page from \(shorten(host))", "Fetch a page from \(host)")

        case nil:
            let kind = humanizeKind(permission)
            guard !kind.isEmpty else {
                return ("approve a requested operation", "Approve a requested operation")
            }
            return (
                bounded(
                    "approve a \(kind) operation",
                    characterLimit: summaryCharacterLimit
                ),
                bounded(
                    "Approve a \(kind) operation",
                    characterLimit: detailCharacterLimit
                )
            )
        }
    }

    /// Turns an identifier such as `external_directory` into spoken words. Derived from the
    /// kind alone, exactly as the Codex adapter derives MCP speech from the canonical tool
    /// name and never from argument values.
    private static func humanizeKind(_ permission: String) -> String {
        permission
            .map { character in
                character.isLetter || character.isNumber ? String(character) : " "
            }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Metadata values are an open-ended per-tool schema. Only strings are read, so a
    /// nested object or array can never be flattened into speech by accident.
    private static func scalar(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string): return string
        default: return nil
        }
    }

    private static func host(of urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url.host
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

    private static func bounded(_ text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else { return text }
        let contentLimit = max(0, characterLimit - 1)
        var result = String(text.prefix(contentLimit))
        if let lastSpace = result.lastIndex(of: " ") {
            result = String(result[..<lastSpace])
        }
        return result + "…"
    }
}
