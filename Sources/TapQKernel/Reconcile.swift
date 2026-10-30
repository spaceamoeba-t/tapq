import Foundation

/// What a restart finds in the journal: the work that was in
/// flight, to be marked lost and told, and the state that survives. Nothing is resent.
struct Reconciliation: Equatable {
    /// To append before anything else happens.
    var lost: [JournalEntry] = []
    /// Agents whose turn or requests were cut off, with their lost permission and question
    /// count. A lost launch is the unfinished task itself.
    var affected: [AgentID: Int] = [:]
    /// Agents whose lost turn had reached them (`sent`), not only a launch yes.
    var delivered: Set<AgentID> = []
    /// Agents whose last reply was journaled but never spoken.
    var unheardReplies: Set<AgentID> = []
    /// The last `finished` per agent, so "read it all" survives a relaunch.
    var heldReplies: [AgentID: HeldReply] = [:]
    var lastSpeechID = 0
    /// How each chat agent's lost turn was sent: as its last start recorded, else as this run
    /// reaches it. It says how that turn is told.
    var chatBackends: [AgentID: ChatBackend] = [:]

    /// One sentence per agent that lost work or has a reply it never heard.
    var sentences: [String] {
        AgentID.allCases.compactMap { agent in
            Sentences.resumed(agent, openRequests: affected[agent], unheardReply: unheardReplies.contains(agent),
                              taskDelivered: delivered.contains(agent), chats: chatBackends[agent] ?? .app)
        }
    }
}

enum Reconcile {
    /// `resuming`: the agents that keep their conversations this run (a coding agent, a chat
    /// over the API); `chatBackends`: how each chat agent is reached (2026-10-13).
    static func fold(_ records: [JournalRecord], resuming: Set<AgentID> = [.claude, .codex],
                     chatBackends: [AgentID: ChatBackend] = [:]) -> Reconciliation {
        var result = Reconciliation(chatBackends: chatBackends)
        var openTurns: Set<AgentID> = []
        var deliveredTurns: Set<AgentID> = []
        var openRequests: [AgentID: [(id: String, launch: Bool)]] = [:]
        /// Launch prompts whose yes carried no words: a switch opens no turn (2026-10-12).
        var emptyLaunches: Set<String> = []
        /// Per agent, the session its last start was in.
        var sessions: [AgentID: String] = [:]
        /// Per agent, the sentences that would have told its last reply.
        var untold: [AgentID: Set<String>] = [:]
        for record in records {
            switch record.entry {
            case .sent(let agent, _):
                openTurns.insert(agent)
                deliveredTurns.insert(agent)
            case .resolved(let agent, let id, let decision):
                openRequests[agent]?.removeAll { $0.id == id }
                // A launch yes opens the turn that carries the held instruction.
                if decision == .launch(yes: true), !emptyLaunches.contains(id) { openTurns.insert(agent) }
            case .started(let agent, let id, let chats):
                if let chats { result.chatBackends[agent] = chats }
                // Another conversation: the last reply was the old one's (2026-10-12). Each start
                // of a chat in the user's app is a new chat, whatever id it gave (2026-10-13).
                if !resuming.contains(agent) || sessions[agent].map({ $0 != id }) == true {
                    result.heldReplies[agent] = nil
                    untold[agent] = nil
                }
                sessions[agent] = id
            case .finished(let agent, let text):
                openTurns.remove(agent)
                deliveredTurns.remove(agent)
                result.heldReplies[agent] = HeldReply(seq: record.seq, text: text)
                untold[agent] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
                    : [Sentences.finished(agent, text), Sentences.summaryFailed(agent),
                       Sentences.readAll(agent, held: text)]
            case .summarized(let agent, let seq, let summary) where seq == result.heldReplies[agent]?.seq:
                untold[agent]?.insert(Sentences.summary(agent, summary))
            case .stopped(let agent), .failed(let agent, _), .lost(let agent, .turn):
                openTurns.remove(agent)
                deliveredTurns.remove(agent)
            case .launchAsked(let agent, let id, _, _, let held, _):
                openRequests[agent, default: []].append((id, true))
                if held.isEmpty { emptyLaunches.insert(id) }
            case .launching(let agent, _, let held):
                // A start without a yes (2026-10-24) opens the turn that carries its words, as a
                // launch yes does.
                if !held.isEmpty { openTurns.insert(agent) }
            case .permission(let agent, let request):
                openRequests[agent, default: []].append((request.id, false))
            case .question(let agent, let request):
                openRequests[agent, default: []].append((request.id, false))
            case .withdrawn(let agent, let id), .lost(let agent, .request(let id)):
                openRequests[agent]?.removeAll { $0.id == id }
            case .spoke(let id, let text):
                result.lastSpeechID = max(result.lastSpeechID, id.raw)
                for (agent, sentences) in untold
                where sentences.contains(text) || text.hasSuffix(Sentences.unheardReply(agent)) {
                    untold[agent] = nil
                }
            default:
                break
            }
        }
        result.unheardReplies = Set(untold.keys)
        for agent in AgentID.allCases {
            let requests = openRequests[agent] ?? []
            let turn = openTurns.contains(agent)
            if turn { result.lost.append(.lost(agent: agent, .turn)) }
            if turn, deliveredTurns.contains(agent) { result.delivered.insert(agent) }
            result.lost += requests.map { .lost(agent: agent, .request(id: $0.id)) }
            if turn || !requests.isEmpty {
                result.affected[agent] = requests.filter { !$0.launch }.count
            }
        }
        return result
    }
}

extension AgentID {
    /// Whether the agent, once resumed, may take up a task a restart cut off. Codex's thread
    /// keeps the instruction it was given, and Codex did that task too when given the next one
    /// (live 2026-10-11, 2 of 2); Claude Code did not (0 of 3).
    var mayRetakeLostTask: Bool { self == .codex }
}
