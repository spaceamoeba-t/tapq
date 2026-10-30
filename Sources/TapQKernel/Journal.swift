import Foundation

// `journal.jsonl`, schema version 2: one record per line, `{"seq":n,"at":ms,"e":"<case>",…}`.
// A v1 `transcript.jsonl` is refused with "this workspace has a transcript from an older
// TapQ; clear it". The encoding is hand-written and pinned by tests.

public enum LostItem: Sendable, Equatable, Codable {
    /// A send with no finished/stopped/failed after it.
    case turn
    /// A pending launch/permission/question.
    case request(id: String)
}

public enum RefusalReason: String, Sendable, Codable {
    case gateClosed, notHead, nothingPending, incompleteAnswer, notInstalled, emptyMessage, unreadable
    /// Only in records of 2026-10-12, before routing by the model: a yes, no or answer for an
    /// agent named inside the sentence.
    case consentByMention
    /// The intent model could not tell which agent a yes, no or answer is for (§4.2): TapQ asks.
    case agentUnclear
    /// A switch or a new conversation for an agent that is working (2026-10-12); since
    /// 2026-10-13 also words for a chat agent while it answers, which cannot be steered.
    case busy
    /// A conversation number TapQ did not read for that agent; a chat agent's are never read
    /// (2026-10-13).
    case noSuchConversation
    /// A resume of a conversation a process other than TapQ's has open (2026-10-12).
    case openElsewhere
}

/// What a start opens (2026-10-12; without a yes since 2026-10-24, but for a switch): the
/// conversation the agent has (resumed when there is one), one the user chose from those TapQ
/// read or the picker chose, a new one, or the chat the user's app shows.
public enum LaunchTarget: Sendable, Equatable, Codable {
    case saved
    case conversation(id: String)
    case new
    /// A chat in the user's app carries on the chat the app shows (2026-10-24).
    case shown
}

public enum JournalEntry: Sendable, Equatable {
    /// Every utterance with words, as heard. `agent` is in records before routing by the model
    /// (2026-10-12); since, the agent is the intent model's, on `decided`.
    case heard(itemID: String, agent: AgentID?, text: String)
    /// `agent`: the agent the intent is for; nil when the model could not tell (TapQ asked
    /// which), and in records before 2026-10-12.
    case decided(itemID: String, agent: AgentID? = nil, intent: Intent)
    /// Call-bound failure, spoken.
    case decisionFailed(itemID: String, reason: String)
    case refused(itemID: String, reason: RefusalReason)
    /// `held`: the words sent once started; empty for a switch with nothing to say. `target` is
    /// written only when it is not `.saved`.
    case launchAsked(agent: AgentID, requestID: String, folder: String, resume: Bool, held: String,
                     target: LaunchTarget = .saved)
    /// A start made without asking (maintainer, 2026-10-24): an instruction to an agent that
    /// was off, into the conversation the picker chose, or a new conversation. `held`: the words
    /// sent once started; empty for a new conversation with nothing to say. `target` is written
    /// only when it is not `.saved`.
    case launching(agent: AgentID, target: LaunchTarget = .saved, held: String)
    /// `chats`: how a chat agent was reached by this start, in the app or over the API
    /// (2026-10-13), so a restart tells its lost turn as it was; nil for a coding agent and in
    /// records before.
    case started(agent: AgentID, sessionID: String, chats: ChatBackend? = nil)
    case sent(agent: AgentID, text: String)
    case interruptSent(agent: AgentID)
    case resolved(agent: AgentID, requestID: String, decision: Resolution)
    case permission(agent: AgentID, PermissionRequest)
    case question(agent: AgentID, QuestionRequest)
    case withdrawn(agent: AgentID, requestID: String)
    /// The held original.
    case finished(agent: AgentID, text: String)
    case stopped(agent: AgentID)
    case failed(agent: AgentID, reason: String)
    case summarized(agent: AgentID, finishedSeq: Int, summary: String)
    /// Appended before `speak()`.
    case spoke(id: SpeechID, text: String)
    case lost(agent: AgentID, LostItem)
}

public enum Resolution: Sendable, Equatable, Codable {
    case launch(yes: Bool), permission(PermissionDecision), answers([[String]])
}

public struct JournalRecord: Sendable, Equatable, Codable {
    public let seq: Int
    public let atMillis: Int
    public let entry: JournalEntry

    public init(seq: Int, atMillis: Int, entry: JournalEntry) {
        self.seq = seq
        self.atMillis = atMillis
        self.entry = entry
    }

    private enum Key: String, CodingKey {
        case seq, at, e, item, agent, text, intent, reason, requestID, folder, resume, held, target,
             sessionID, decision, permission, question, finishedSeq, summary, speech, lost, chats
    }

    /// One flat object per line: `seq`, `at`, `e` (the case name), then the case's fields.
    /// Payload types (`Intent`, `Resolution`, the requests, `LostItem`) nest as their own
    /// `Codable` encoding.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(atMillis, forKey: .at)
        try c.encode(entry.name, forKey: .e)
        switch entry {
        case .heard(let item, let agent, let text):
            try c.encode(item, forKey: .item)
            try c.encodeIfPresent(agent, forKey: .agent)
            try c.encode(text, forKey: .text)
        case .decided(let item, let agent, let intent):
            try c.encode(item, forKey: .item)
            try c.encodeIfPresent(agent, forKey: .agent)
            try c.encode(intent, forKey: .intent)
        case .decisionFailed(let item, let reason):
            try c.encode(item, forKey: .item)
            try c.encode(reason, forKey: .reason)
        case .refused(let item, let reason):
            try c.encode(item, forKey: .item)
            try c.encode(reason, forKey: .reason)
        case .launchAsked(let agent, let requestID, let folder, let resume, let held, let target):
            try c.encode(agent, forKey: .agent)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(folder, forKey: .folder)
            try c.encode(resume, forKey: .resume)
            try c.encode(held, forKey: .held)
            if target != .saved { try c.encode(target, forKey: .target) }
        case .launching(let agent, let target, let held):
            try c.encode(agent, forKey: .agent)
            if target != .saved { try c.encode(target, forKey: .target) }
            try c.encode(held, forKey: .held)
        case .started(let agent, let sessionID, let chats):
            try c.encode(agent, forKey: .agent)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encodeIfPresent(chats, forKey: .chats)
        case .sent(let agent, let text), .finished(let agent, let text):
            try c.encode(agent, forKey: .agent)
            try c.encode(text, forKey: .text)
        case .interruptSent(let agent), .stopped(let agent):
            try c.encode(agent, forKey: .agent)
        case .resolved(let agent, let requestID, let decision):
            try c.encode(agent, forKey: .agent)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(decision, forKey: .decision)
        case .permission(let agent, let request):
            try c.encode(agent, forKey: .agent)
            try c.encode(request, forKey: .permission)
        case .question(let agent, let request):
            try c.encode(agent, forKey: .agent)
            try c.encode(request, forKey: .question)
        case .withdrawn(let agent, let requestID):
            try c.encode(agent, forKey: .agent)
            try c.encode(requestID, forKey: .requestID)
        case .failed(let agent, let reason):
            try c.encode(agent, forKey: .agent)
            try c.encode(reason, forKey: .reason)
        case .summarized(let agent, let finishedSeq, let summary):
            try c.encode(agent, forKey: .agent)
            try c.encode(finishedSeq, forKey: .finishedSeq)
            try c.encode(summary, forKey: .summary)
        case .spoke(let id, let text):
            try c.encode(id.raw, forKey: .speech)
            try c.encode(text, forKey: .text)
        case .lost(let agent, let item):
            try c.encode(agent, forKey: .agent)
            try c.encode(item, forKey: .lost)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func value<T: Decodable>(_ key: Key) throws -> T { try c.decode(T.self, forKey: key) }
        seq = try value(.seq)
        atMillis = try value(.at)
        let name: String = try value(.e)
        switch name {
        case "heard":
            entry = .heard(itemID: try value(.item), agent: try c.decodeIfPresent(AgentID.self, forKey: .agent),
                           text: try value(.text))
        case "decided":
            entry = .decided(itemID: try value(.item), agent: try c.decodeIfPresent(AgentID.self, forKey: .agent),
                             intent: try value(.intent))
        case "decisionFailed":
            entry = .decisionFailed(itemID: try value(.item), reason: try value(.reason))
        case "refused":
            entry = .refused(itemID: try value(.item), reason: try value(.reason))
        case "launchAsked":
            entry = .launchAsked(agent: try value(.agent), requestID: try value(.requestID),
                                 folder: try value(.folder), resume: try value(.resume),
                                 held: try value(.held),
                                 target: try c.decodeIfPresent(LaunchTarget.self, forKey: .target) ?? .saved)
        case "launching":
            entry = .launching(agent: try value(.agent),
                               target: try c.decodeIfPresent(LaunchTarget.self, forKey: .target) ?? .saved,
                               held: try value(.held))
        case "started":
            entry = .started(agent: try value(.agent), sessionID: try value(.sessionID),
                             chats: try c.decodeIfPresent(ChatBackend.self, forKey: .chats))
        case "sent":
            entry = .sent(agent: try value(.agent), text: try value(.text))
        case "interruptSent":
            entry = .interruptSent(agent: try value(.agent))
        case "resolved":
            entry = .resolved(agent: try value(.agent), requestID: try value(.requestID),
                              decision: try value(.decision))
        case "permission":
            entry = .permission(agent: try value(.agent), try value(.permission))
        case "question":
            entry = .question(agent: try value(.agent), try value(.question))
        case "withdrawn":
            entry = .withdrawn(agent: try value(.agent), requestID: try value(.requestID))
        case "finished":
            entry = .finished(agent: try value(.agent), text: try value(.text))
        case "stopped":
            entry = .stopped(agent: try value(.agent))
        case "failed":
            entry = .failed(agent: try value(.agent), reason: try value(.reason))
        case "summarized":
            entry = .summarized(agent: try value(.agent), finishedSeq: try value(.finishedSeq),
                                summary: try value(.summary))
        case "spoke":
            entry = .spoke(id: SpeechID(raw: try value(.speech)), text: try value(.text))
        case "lost":
            entry = .lost(agent: try value(.agent), try value(.lost))
        default:
            throw DecodingError.dataCorruptedError(forKey: .e, in: c,
                                                   debugDescription: "unknown entry '\(name)'")
        }
    }
}

extension JournalEntry {
    /// The case name, as the `e` field of its line.
    var name: String {
        switch self {
        case .heard: return "heard"
        case .decided: return "decided"
        case .decisionFailed: return "decisionFailed"
        case .refused: return "refused"
        case .launchAsked: return "launchAsked"
        case .launching: return "launching"
        case .started: return "started"
        case .sent: return "sent"
        case .interruptSent: return "interruptSent"
        case .resolved: return "resolved"
        case .permission: return "permission"
        case .question: return "question"
        case .withdrawn: return "withdrawn"
        case .finished: return "finished"
        case .stopped: return "stopped"
        case .failed: return "failed"
        case .summarized: return "summarized"
        case .spoke: return "spoke"
        case .lost: return "lost"
        }
    }
}

@MainActor public protocol JournalPersisting: AnyObject {
    /// Returns after write + fsync of line and newline.
    func append(_ record: JournalRecord) throws
    /// Torn-tail rule: a final fragment without a trailing newline is dropped and the file
    /// truncated to the last newline; any other undecodable line throws.
    func load() throws -> [JournalRecord]
}

/// The kernel's record of what was heard, decided and done. Append-only: every entry is
/// on disk before the action it describes (invariant 2), and nothing is ever rewritten.
/// Only the last `seq` stays in memory.
@MainActor public final class Journal {
    private let store: any JournalPersisting
    private let now: @Sendable () -> Date
    public private(set) var lastSeq = 0

    public init(store: any JournalPersisting, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    /// Every record so far, once, for reconciliation.
    public func load() throws -> [JournalRecord] {
        let records = try store.load()
        lastSeq = records.last?.seq ?? 0
        return records
    }

    /// `seq` continues from the last record; `at` is whole epoch milliseconds, the one date
    /// form a JSONL round trip keeps exactly.
    @discardableResult public func append(_ entry: JournalEntry) throws -> JournalRecord {
        let record = JournalRecord(seq: lastSeq + 1,
                                   atMillis: Int((now().timeIntervalSince1970 * 1000).rounded()),
                                   entry: entry)
        try store.append(record)
        lastSeq = record.seq
        return record
    }
}
