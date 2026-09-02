import Foundation
import TapQContracts

/// One line of the session book: something that happened to one agent session's standing
/// with TapQ (`docs/SESSION_FOCUS_PLAN.md` §4).
///
/// Append-only events rather than a mutable record per session, for the reason the wearer's
/// memory is: a runtime that dies between two of them leaves an honest trace — a `started`
/// with no `ended` is a session whose end TapQ did not see — and a reader folds the events
/// into the state it needs (``SessionBookRecord``).
///
/// This file is the one place a session identifier and a working directory are written
/// beside a goal. It is **not** speech: nothing reads it into a prompt or a sentence, and
/// the wearer's memory (`wearer-conversation.jsonl`) carries the spoken half of the same
/// events with neither field. A restart reads it to know which sessions are detached, and
/// a later "go back to the previous session" would read it to know where that was.
public struct SessionBookEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// TapQ started the session, or first saw a keyboard session and gave it the focus.
        case started
        /// The session lost the focus. `ending` says how: back on the keyboard, or stopped.
        case detached
        /// The session is over: a session TapQ started exited.
        case ended
        /// The session's working directory became known — from a hook that carried it —
        /// after the session was first recorded.
        case directory
    }

    public let timestamp: Date
    public let kind: Kind
    public let sessionID: String
    public let agentID: String
    public let agentDisplayName: String
    /// Empty when unknown.
    public let workingDirectory: String
    /// The wearer's goal for a session TapQ started; empty for a keyboard session.
    public let goal: String
    public let ownedByTapQ: Bool
    /// For `detached` and `ended`: the recorded outcome. Empty otherwise.
    public let ending: String

    public init(
        timestamp: Date,
        kind: Kind,
        sessionID: String,
        agentID: String,
        agentDisplayName: String,
        workingDirectory: String = "",
        goal: String = "",
        ownedByTapQ: Bool = false,
        ending: String = ""
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentDisplayName = agentDisplayName
        self.workingDirectory = workingDirectory
        self.goal = goal
        self.ownedByTapQ = ownedByTapQ
        self.ending = ending
    }

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case kind
        case sessionID = "session"
        case agentID = "agent"
        case agentDisplayName = "agent_name"
        case workingDirectory = "dir"
        case goal
        case ownedByTapQ = "owned"
        case ending
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stamp = try container.decode(String.self, forKey: .timestamp)
        guard let timestamp = WearerConversationTimestamp.date(from: stamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: container, debugDescription: "unreadable timestamp"
            )
        }
        self.timestamp = timestamp
        kind = try container.decode(Kind.self, forKey: .kind)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID) ?? ""
        agentDisplayName = try container.decodeIfPresent(String.self, forKey: .agentDisplayName)
            ?? ""
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
            ?? ""
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        ownedByTapQ = try container.decodeIfPresent(Bool.self, forKey: .ownedByTapQ) ?? false
        ending = try container.decodeIfPresent(String.self, forKey: .ending) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WearerConversationTimestamp.string(from: timestamp), forKey: .timestamp)
        try container.encode(kind, forKey: .kind)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(agentID, forKey: .agentID)
        try container.encode(agentDisplayName, forKey: .agentDisplayName)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(goal, forKey: .goal)
        try container.encode(ownedByTapQ, forKey: .ownedByTapQ)
        try container.encode(ending, forKey: .ending)
    }
}

/// One session's standing, folded from its events.
public struct SessionBookRecord: Sendable, Equatable {
    public let sessionID: String
    public let agentID: String
    public let agentDisplayName: String
    public var workingDirectory: String
    public let goal: String
    public let ownedByTapQ: Bool
    public let startedAt: Date
    public var detachedAt: Date?
    public var endedAt: Date?
    /// The last recorded outcome: how it was detached, or how it ended. Empty while it has
    /// the focus.
    public var ending: String

    /// Whether the session is still the one that answers for its agent, as far as the book
    /// knows: started, not detached, not ended.
    public var hasFocus: Bool { detachedAt == nil && endedAt == nil }
    /// Detached and not yet over.
    public var isDetached: Bool { detachedAt != nil && endedAt == nil }
}

/// The durable book of agent sessions and their standing with TapQ
/// (`docs/SESSION_FOCUS_PLAN.md` §4): `sessions.jsonl`, beside the wearer's memory.
///
/// Small, append-only, and bounded by event count rather than by age: sessions are few,
/// and what a restart needs is the last few of them. Over ``maximumEvents`` the events of
/// ended sessions are dropped oldest first, then the oldest events of all, and the file is
/// rewritten. Every file failure is swallowed and diagnosed, on the same posture as the
/// wearer's memory: TapQ forgetting a session is loud in the log and is not a reason to
/// stop listening.
@MainActor public final class SessionBook {
    public nonisolated static let fileName = "sessions.jsonl"
    /// Comfortably a month of sessions at a handful of events each.
    public nonisolated static let maximumEvents = 400

    public let fileURL: URL
    private let clock: @Sendable () -> Date
    private let diagnostics: TapQDiagnosticEmitter
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var events: [SessionBookEvent] = []

    /// - Parameters:
    ///   - directory: the runtime's application-support directory, already prepared.
    ///   - clock: the timestamp source.
    public init(
        directory: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.clock = clock
        self.diagnostics = TapQDiagnosticEmitter(category: "SessionBook", sink: diagnosticSink)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        load()
    }

    // MARK: - Recording

    /// TapQ started a session, or first saw a keyboard one and gave it the focus.
    public func recordStarted(
        sessionID: String,
        agent: AgentIdentity,
        workingDirectory: String? = nil,
        goal: String = "",
        ownedByTapQ: Bool = false
    ) {
        append(SessionBookEvent(
            timestamp: clock(),
            kind: .started,
            sessionID: sessionID,
            agentID: agent.id,
            agentDisplayName: agent.displayName,
            workingDirectory: workingDirectory ?? "",
            goal: goal,
            ownedByTapQ: ownedByTapQ
        ))
    }

    /// The session lost the focus. `ending` is one of the ``WearerSessionEvent`` words.
    public func recordDetached(sessionID: String, agent: AgentIdentity, ending: String) {
        append(SessionBookEvent(
            timestamp: clock(),
            kind: .detached,
            sessionID: sessionID,
            agentID: agent.id,
            agentDisplayName: agent.displayName,
            ending: ending
        ))
    }

    /// A session TapQ started is over.
    public func recordEnded(sessionID: String, agent: AgentIdentity, ending: String) {
        append(SessionBookEvent(
            timestamp: clock(),
            kind: .ended,
            sessionID: sessionID,
            agentID: agent.id,
            agentDisplayName: agent.displayName,
            ending: ending
        ))
    }

    /// The session's working directory became known. Recorded once per session: a
    /// directory already on the books is not written again.
    public func noteWorkingDirectory(sessionID: String, agent: AgentIdentity, path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let record = record(sessionID: sessionID), record.workingDirectory.isEmpty
        else { return }
        append(SessionBookEvent(
            timestamp: clock(),
            kind: .directory,
            sessionID: sessionID,
            agentID: agent.id,
            agentDisplayName: agent.displayName,
            workingDirectory: trimmed
        ))
    }

    // MARK: - Reading

    /// Every session the book knows, oldest first.
    public func records() -> [SessionBookRecord] {
        var order: [String] = []
        var byID: [String: SessionBookRecord] = [:]
        for event in events {
            switch event.kind {
            case .started:
                if byID[event.sessionID] == nil { order.append(event.sessionID) }
                byID[event.sessionID] = SessionBookRecord(
                    sessionID: event.sessionID,
                    agentID: event.agentID,
                    agentDisplayName: event.agentDisplayName,
                    workingDirectory: event.workingDirectory,
                    goal: event.goal,
                    ownedByTapQ: event.ownedByTapQ,
                    startedAt: event.timestamp,
                    ending: ""
                )
            case .detached:
                guard var record = byID[event.sessionID] else { continue }
                record.detachedAt = event.timestamp
                record.ending = event.ending
                byID[event.sessionID] = record
            case .ended:
                guard var record = byID[event.sessionID] else { continue }
                record.endedAt = event.timestamp
                record.ending = event.ending
                byID[event.sessionID] = record
            case .directory:
                guard var record = byID[event.sessionID] else { continue }
                if record.workingDirectory.isEmpty {
                    record.workingDirectory = event.workingDirectory
                }
                byID[event.sessionID] = record
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// One session's standing, or `nil` for a session the book never saw start.
    public func record(sessionID: String) -> SessionBookRecord? {
        records().first { $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame }
    }

    /// The session the book last gave `agentID`'s focus and has not seen leave it.
    public func focusedSession(agentID: String) -> SessionBookRecord? {
        records().last { $0.agentID == agentID && $0.hasFocus }
    }

    /// The sessions of `agentID` that are detached and not over, oldest first. What a
    /// restart marks detached before any hook arrives.
    public func detachedSessions(agentID: String) -> [SessionBookRecord] {
        records().filter { $0.agentID == agentID && $0.isDetached }
    }

    /// The working directory on record for a session, or `nil` when none is.
    public func workingDirectory(sessionID: String) -> String? {
        guard let path = record(sessionID: sessionID)?.workingDirectory, !path.isEmpty else {
            return nil
        }
        return path
    }

    /// How many events the book holds. For tests.
    public var eventCount: Int { events.count }

    // MARK: - The file

    private func append(_ event: SessionBookEvent) {
        events.append(event)
        if events.count > Self.maximumEvents {
            compact()
            rewrite()
            return
        }
        guard let line = encoded(event) else { return }
        do {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            diagnostics.record("append_failed", level: .warning, fields: [
                "error": String(describing: error),
            ])
        }
    }

    /// Drops what the bound does not allow: the events of ended sessions, oldest first,
    /// and then the oldest events of all.
    private func compact() {
        let target = Self.maximumEvents * 3 / 4
        let ended = Set(records().filter { $0.endedAt != nil }.map(\.sessionID))
        var kept: [SessionBookEvent] = []
        var dropped = 0
        for event in events {
            if events.count - dropped > target, ended.contains(event.sessionID) {
                dropped += 1
                continue
            }
            kept.append(event)
        }
        if kept.count > target {
            kept.removeFirst(kept.count - target)
        }
        diagnostics.record("compacted", fields: [
            "dropped": "\(events.count - kept.count)",
            "kept": "\(kept.count)",
        ])
        events = kept
    }

    private func rewrite() {
        var data = Data()
        for event in events {
            guard let line = encoded(event) else { continue }
            data.append(line)
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            diagnostics.record("rewrite_failed", level: .warning, fields: [
                "error": String(describing: error),
            ])
        }
    }

    private func encoded(_ event: SessionBookEvent) -> Data? {
        do {
            var line = try encoder.encode(event)
            line.append(UInt8(ascii: "\n"))
            return line
        } catch {
            diagnostics.record("encode_failed", level: .warning, fields: [
                "error": String(describing: error),
            ])
            return nil
        }
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return }
        var loaded: [SessionBookEvent] = []
        var torn = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let event = try? decoder.decode(SessionBookEvent.self, from: Data(line)) else {
                torn += 1
                continue
            }
            loaded.append(event)
        }
        events = loaded
        diagnostics.record("loaded", fields: [
            "events": "\(loaded.count)",
            "torn": "\(torn)",
        ])
    }
}
