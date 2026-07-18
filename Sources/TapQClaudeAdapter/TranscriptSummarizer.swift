import Foundation
import TapQWireProtocol

/// Best-effort one-line gloss of what the agent last said, pulled from the JSONL
/// transcript Claude Code passes as `transcript_path`. Feeds a notification's spoken
/// summary ("Claude finished. <gloss>"). Any parse failure returns nil — never throws.
public enum TranscriptSummarizer {
    public static func lastAssistantLine(transcriptPath: String, maxWords: Int = 16) -> String? {
        guard let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode([String: JSONValue].self, from: data),
                  entry["type"]?.stringValue == "assistant",
                  let message = entry["message"]?.objectValue,
                  let content = message["content"]?.arrayValue else { continue }

            let spoken = content
                .compactMap { block -> String? in
                    block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
                }
                .joined(separator: " ")

            if let condensed = condense(spoken, maxWords: maxWords) { return condensed }
        }
        return nil
    }

    private static func condense(_ text: String, maxWords: Int) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxWords else { return collapsed.joined(separator: " ") }
        return collapsed.prefix(maxWords).joined(separator: " ") + "…"
    }
}
