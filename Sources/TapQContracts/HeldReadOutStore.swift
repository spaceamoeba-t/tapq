import Foundation

/// The original of the last reply TapQ summarized: what "read it all" reads.
///
/// One slot, and every reply TapQ reads out writes it: a summarized reply holds its original,
/// and a reply read in full clears it. So "the rest" always means the rest of the last reply,
/// never an older one the user has since heard past. Only complete replies reach it, because
/// only complete replies are read out.
@MainActor public final class HeldReadOutStore {
    /// Whose reply is held.
    public enum Source: String, Sendable, Equatable {
        /// A coding agent's final reply.
        case agentReply = "agent_reply"
        /// A desktop chat app's answer.
        case chatAnswer = "chat_answer"
    }

    /// A held reply: the words "read it all" says, and whose they are.
    public struct ReadOut: Sendable, Equatable {
        public let text: String
        public let source: Source

        public init(text: String, source: Source) {
            self.text = text
            self.source = source
        }
    }

    /// What "read it all" reads now, or `nil` when the last reply was read in full.
    public private(set) var latest: ReadOut?

    public init() {}

    /// Holds the original of a reply that was summarized.
    public func hold(_ original: String, source: Source) {
        latest = ReadOut(text: original, source: source)
    }

    /// Records that the last reply was read in full, so there is no rest to read.
    public func clear() {
        latest = nil
    }
}
