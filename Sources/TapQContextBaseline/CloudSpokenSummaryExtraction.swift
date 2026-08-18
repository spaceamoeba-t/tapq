import Foundation
import TapQContracts

/// Provider-neutral structured output shared by cloud spoken summarizers.
struct CloudSpokenSummaryExtraction: Decodable {
    let sentence: String
    let detail: String
}

enum CloudSpokenSummaryContract {
    /// Decodes a provider's JSON payload. The caps are re-applied by ``SpokenSummary``
    /// on the way out, so a model that ignores the length guidance cannot lengthen an
    /// utterance — it can only waste tokens.
    static func decode(_ text: String) -> SpokenSummary? {
        guard let data = text.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(
                  CloudSpokenSummaryExtraction.self,
                  from: data
              ) else { return nil }
        return SpokenSummary.make(
            sentence: extraction.sentence,
            detail: extraction.detail
        )
    }

    static let instructions = """
        You read the final reply a coding assistant sent to its user and write what a \
        wearable assistant should say out loud about it. Produce:
        - sentence: one spoken-friendly sentence, at most 120 characters, saying what \
        the assistant did or is asking about. No markdown, no code, no file paths.
        - detail: at most 320 characters of extra spoken context the user can ask for, \
        covering specifics the sentence left out. Empty when the sentence says everything.
        Never invent work the reply does not describe, never ask the user a question, \
        and never tell the user to approve or run anything.
        """

    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "sentence": [
                "type": "string",
                "description": "One spoken-friendly sentence, at most 120 characters.",
            ],
            "detail": [
                "type": "string",
                "description": "At most 320 characters of extra spoken context; may be empty.",
            ],
        ],
        "required": ["sentence", "detail"],
        "additionalProperties": false,
    ]
}
