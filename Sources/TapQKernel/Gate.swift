import Foundation

/// Invariant 6: whether an approve, deny, answer or launch yes may act. Fail closed.
///
/// Both instants are real events on the capture clock: `promptPlayedAt` is the player's
/// drain report for a verbatim reading of the head's prompt, and `speechStartedAt` is the
/// VAD's start of the utterance. Speech that began before the prompt finished playing
/// cannot be an answer to it.
enum Gate {
    /// nil = the gate is open.
    static func refusal(requestID: String, head: PendingRequest,
                        speechStartedAt: TimeInterval?) -> RefusalReason? {
        guard head.id == requestID else { return .notHead }
        guard let played = head.promptPlayedAt, let started = speechStartedAt, started > played else {
            return .gateClosed
        }
        return nil
    }
}

extension Intent {
    /// The request an approve, deny or answer acts on. The kernel filled it from the head it
    /// put in the input; the gate checks that it is still the head.
    var requestID: String? {
        switch self {
        case .approve(let id, _), .deny(let id, _), .answer(let id, _): return id
        case .instruct, .interrupt, .readAll, .status, .unclear, .listConversations, .moreConversations,
             .switchConversation, .newConversation:
            return nil
        }
    }

    /// A yes, no or answer: what the gate guards, and what may go only to a request the user
    /// named when more than one was heard.
    public var isConsent: Bool { requestID != nil }

    /// The case name, for the status channel's `lastHeard.action`.
    var name: String {
        switch self {
        case .instruct: return "instruct"
        case .interrupt: return "interrupt"
        case .approve: return "approve"
        case .deny: return "deny"
        case .answer: return "answer"
        case .readAll: return "readAll"
        case .status: return "status"
        case .unclear: return "unclear"
        case .listConversations: return "listConversations"
        case .moreConversations: return "moreConversations"
        case .switchConversation: return "switchConversation"
        case .newConversation: return "newConversation"
        }
    }
}
