import Foundation

/// What TapQ will say, in three bands. The head of the highest
/// non-empty band plays next: an ack (the reply to the user's own utterance) before a
/// request (head prompts, at most one per agent, oldest first) before a result (FIFO).
///
/// The queue only orders. Whether anything may start now (nothing playing, the user not
/// speaking) is the kernel's check.
struct SpeechQueue: Equatable {
    enum Band: String { case ack, request, result }

    struct Item: Equatable {
        let band: Band
        let text: String
        /// Set for a consent prompt: the request whose head prompt this is.
        let prompt: Prompt?
        /// The agent whose words these are (a request, a reply, its failure), for routing's
        /// "heard from last" (§4.2); nil for TapQ's own acks.
        var agent: AgentID? = nil
    }

    struct Prompt: Equatable {
        let agent: AgentID
        let requestID: String
    }

    private var ack: [Item] = []
    private var request: [Item] = []
    private var result: [Item] = []

    mutating func enqueue(_ text: String, band: Band, agent: AgentID? = nil) {
        let item = Item(band: band, text: text, prompt: nil, agent: agent)
        switch band {
        case .ack: ack.append(item)
        case .request: request.append(item)
        case .result: result.append(item)
        }
    }

    /// Queues `agent`'s head prompt, replacing any prompt of that agent still waiting. A
    /// re-ask goes `first`: it answers what the user just said.
    mutating func enqueuePrompt(_ text: String, agent: AgentID, requestID: String, first: Bool = false) {
        removePrompt(of: agent)
        let item = Item(band: .request, text: text, prompt: Prompt(agent: agent, requestID: requestID), agent: agent)
        request.insert(item, at: first ? 0 : request.endIndex)
    }

    mutating func removePrompt(of agent: AgentID) {
        request.removeAll { $0.prompt?.agent == agent }
    }

    mutating func next() -> Item? {
        if !ack.isEmpty { return ack.removeFirst() }
        if !request.isEmpty { return request.removeFirst() }
        if !result.isEmpty { return result.removeFirst() }
        return nil
    }
}
