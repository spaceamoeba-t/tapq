import Foundation

/// Extracts the text of Claude's final reply from a session transcript (JSONL).
///
/// Reads only the tail of the file so a very long session can't stall the hook,
/// scans backward to the last `assistant` line, then widens to the trailing run of
/// consecutive `assistant` lines (a streamed reply spans several) and joins their
/// text blocks in file order. Any I/O or parse problem returns nil — callers fail open.
public enum TranscriptReader {
    /// Bytes read from the end of the transcript. The transcript is appended in whole
    /// lines, so starting mid-line is harmless: the partial first line fails to parse
    /// and is skipped.
    static let tailBytes: UInt64 = 2 * 1024 * 1024

    public static func lastAssistantText(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > tailBytes ? size - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        var collected: [String] = []
        var inTrailingAssistantRun = false
        while let line = lines.popLast() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                if inTrailingAssistantRun { break }
                continue
            }
            if obj["type"] as? String == "assistant" {
                inTrailingAssistantRun = true
                if let text = assistantText(obj) { collected.append(text) }
            } else if inTrailingAssistantRun {
                break
            }
        }
        guard !collected.isEmpty else { return nil }
        return collected.reversed().joined(separator: "\n\n")
    }

    private static func assistantText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = texts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }
}
