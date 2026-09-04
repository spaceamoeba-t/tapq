import Foundation
import TapQContracts

/// One transcript entry selected as evidence for an answer, in the order it happened.
public struct WorkQuestionSlice: Sendable, Equatable {
    /// The entry's position in the tail it was taken from, so the model reads the history
    /// in order and a diagnostic can say *which* slices were used without quoting any.
    public let index: Int
    public let text: String

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

/// A wearer's question about an agent's work, with the history it is to be answered from.
public struct WorkQuestionRequest: Sendable, Equatable {
    /// The question in the wearer's own words, as the realtime model reported it.
    public let question: String
    /// The agent whose work this is, by display name only — "Claude Code", never a session
    /// identifier. `nil` when only one agent is connected and the wearer named nobody.
    public let agentDisplayName: String?
    /// The selected history, oldest first.
    public let slices: [WorkQuestionSlice]

    public init(question: String, agentDisplayName: String?, slices: [WorkQuestionSlice]) {
        self.question = question
        self.agentDisplayName = agentDisplayName
        self.slices = slices
    }
}

/// A model that answers a question from transcript slices and nothing else.
///
/// It throws rather than returning `nil`, for the reason ``BoundaryNarrating`` does: there
/// is no local heuristic behind it to fall back to, and an implementation that cannot
/// answer must say so loudly enough for the caller to break the run's voice pipe.
public protocol WorkQuestionAnswering: Sendable {
    func answer(_ request: WorkQuestionRequest) async throws -> String
}

/// The guidance prompt and the structured-output contract for transcript answers.
///
/// Shared by every provider so the same bytes go out whichever one is composed, and so the
/// redaction and quoting rules have one place a test can read them from.
public enum WorkAnswerContract {
    public static let schemaName = "tapq_work_answer"

    /// The whole of what the answer model is told to do.
    ///
    /// Four rules, each of which exists because of a specific way this can go wrong:
    /// inventing work that never happened, paraphrasing a command the wearer has to type,
    /// answering a question the history does not cover, and reading a key out loud.
    ///
    /// The last one is documented as **best effort**, deliberately. The structural
    /// redaction guarantee remains only where it always was — the local path, event memory,
    /// unprompted speech. Here the model has been handed tool output because the wearer
    /// asked what the tool said, and a prompt is the only thing standing between "read me
    /// the output" and reading out a token that happened to be in it. Saying so plainly is
    /// better than implying a guarantee this path does not have.
    public static let instructions = """
        You are the voice of TapQ, a hands-free assistant a person wears while a coding \
        agent works for them. Their hands and eyes are busy; they cannot see a screen. You \
        are given part of a coding agent's session history and one question the wearer \
        asked out loud about it. You write the single answer TapQ will speak. Your output \
        is spoken aloud word for word, so write speech, not prose: no markdown, no bullet \
        points, no headings, no emoji, no stage directions.

        Rules:

        - Answer only from the history you were given. Never infer what the agent probably \
        did, never fill a gap from general knowledge about the tools involved, and never \
        describe work that is not in the history.
        - If the history does not answer the question, say so plainly and briefly — "that \
        isn't in what I can see of the session" — and stop. A short honest miss is worth \
        more to someone who cannot look at a screen than a confident guess.
        - Quote technical tokens exactly: file paths, command lines, flags, identifiers, \
        error codes, test counts, version numbers. Never round a number, never abbreviate \
        a path, never "fix" a spelling inside one. If a command is long, it is still better \
        to say it than to describe it.
        - Never read out a URL or a link — the one exception to quoting a token exactly. Say \
        where it points in a few words — the site, the repository, the page's title — and no \
        more. Never say that a link was left out or that you cannot read one; where it points is the whole of it.
        - Never read out anything that looks like a credential — an API key, a token, a \
        password, a bearer string, a private key — even when asked to read output word for \
        word. Say that the output contains a key and carry on with the rest of it.
        - Keep it to what was asked. Lead with the answer, add only the detail that makes \
        it usable, and do not offer to do anything further.
        """

    public static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "answer": [
                "type": "string",
                "description": "The exact words TapQ will speak. Plain spoken text.",
            ],
        ],
        "required": ["answer"],
        "additionalProperties": false,
    ]

    /// Renders the question and its slices into the model's input.
    ///
    /// Composed here rather than in a provider so every provider sends the same bytes and a
    /// test that asks "what crossed the boundary?" has one place to look.
    public static func input(for request: WorkQuestionRequest) -> String {
        var lines: [String] = []
        if let agent = request.agentDisplayName, !agent.isEmpty {
            lines.append("Agent: \(agent)")
        }
        lines.append("Session history, oldest first (\(request.slices.count) excerpts, "
            + "not necessarily contiguous):")
        for slice in request.slices {
            lines.append("--- excerpt \(slice.index)")
            lines.append(slice.text)
        }
        lines.append("--- end of history")
        lines.append("The wearer asked: \(request.question)")
        return lines.joined(separator: "\n")
    }

    /// Decodes a provider's JSON payload into the sentence TapQ will speak.
    ///
    /// Whitespace is collapsed — a spoken line has no use for newlines — and nothing is
    /// shortened. The model was asked for an answer and this is the answer; a cap here
    /// would clip the very thing the wearer asked to hear.
    public static func decode(_ text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(Extraction.self, from: data) else {
            throw NarrationFailure.malformedResponse
        }
        let spoken = SpokenSummaryText.normalized(extraction.answer)
        guard !spoken.isEmpty else { throw NarrationFailure.emptyOutput }
        return spoken
    }

    private struct Extraction: Decodable {
        let answer: String
    }
}
