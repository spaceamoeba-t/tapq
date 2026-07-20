import Foundation
import TapQContracts

/// Provider-neutral structured output shared by cloud question classifiers.
struct CloudQuestionExtraction: Decodable {
    struct Option: Decodable {
        let label: String
        let description: String
    }

    let kind: String
    let question: String
    let options: [Option]
}

enum CloudQuestionExtractionContract {
    static func decode(_ text: String) -> ResponseQuestionClassification? {
        guard let data = text.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(
                  CloudQuestionExtraction.self,
                  from: data
              ) else { return nil }
        return interpret(extraction)
    }

    static func kind(of classification: ResponseQuestionClassification) -> String {
        switch classification {
        case .noQuestion: return "none"
        case .yesNo: return "yes_no"
        case .multiOption: return "multi_option"
        }
    }

    private static func interpret(
        _ extraction: CloudQuestionExtraction
    ) -> ResponseQuestionClassification? {
        let question = extraction.question.trimmingCharacters(in: .whitespacesAndNewlines)
        switch extraction.kind.lowercased() {
        case "none":
            return .noQuestion
        case "yes_no":
            guard !question.isEmpty else { return nil }
            return .yesNo(question: question)
        case "multi_option":
            guard !question.isEmpty else { return nil }
            let options = extraction.options.prefix(6).compactMap { option -> SelectionOption? in
                let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return nil }
                return SelectionOption(
                    label: label,
                    description: option.description.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard options.count >= 2 else { return nil }
            return .multiOption(question: question, options: options)
        default:
            return nil
        }
    }

    static let instructions = """
        You read the final reply a coding assistant sent to its user and decide whether \
        it is waiting on the user to answer a question. Classify the reply:
        - multi_option: it offers two or more distinct alternatives and asks the user to pick one.
        - yes_no: it asks a single question answerable with yes or no.
        - none: everything else, including statements, rhetorical questions, and open-ended \
        questions with no offered alternatives.
        Summarize the question in at most 12 spoken-friendly words. For multi_option, \
        list each offered alternative in order with a label of at most 4 words and a \
        one-line description. Never invent alternatives the reply does not offer. For \
        yes_no and none, return an empty options array.
        """

    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "kind": [
                "type": "string",
                "enum": ["none", "yes_no", "multi_option"],
            ],
            "question": [
                "type": "string",
                "description": "At most 12 spoken-friendly words; empty when kind is none.",
            ],
            "options": [
                "type": "array",
                "description": "Offered alternatives in order; empty unless kind is multi_option.",
                "items": [
                    "type": "object",
                    "properties": [
                        "label": [
                            "type": "string",
                            "description": "Short spoken label, at most 4 words.",
                        ],
                        "description": [
                            "type": "string",
                            "description": "One short sentence describing this alternative.",
                        ],
                    ],
                    "required": ["label", "description"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["kind", "question", "options"],
        "additionalProperties": false,
    ]
}
