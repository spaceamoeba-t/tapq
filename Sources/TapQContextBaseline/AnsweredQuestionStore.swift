import Foundation

/// Loop safety for final-response question interception.
///
/// Keys use normalized verbatim reply text rather than a model-generated summary so
/// nondeterministic summaries cannot defeat deduplication. A bounded per-session set
/// also terminates two questions re-asked in alternation.
public struct AnsweredQuestionStore: Sendable {
    private var answered: [String: [String]] = [:]

    static let capacity = 8

    public init() {}

    public static func normalize(_ text: String) -> String {
        let collapsed = text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .punctuationCharacters)
        return trimmed.isEmpty ? collapsed : trimmed
    }

    public func isRepeat(session: String, text: String) -> Bool {
        answered[session]?.contains(Self.normalize(text)) ?? false
    }

    public mutating func record(session: String, text: String) {
        let normalized = Self.normalize(text)
        var list = answered[session] ?? []
        guard !list.contains(normalized) else { return }
        list.append(normalized)
        if list.count > Self.capacity {
            list.removeFirst(list.count - Self.capacity)
        }
        answered[session] = list
    }
}
