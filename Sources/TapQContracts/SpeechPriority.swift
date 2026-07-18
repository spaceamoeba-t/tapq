import Foundation

/// Relative urgency of a spoken utterance. Higher priorities preempt lower ones.
public enum SpeechPriority: Int, Comparable, Sendable {
    case progress = 0
    case notification = 1
    case approval = 2

    public static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
