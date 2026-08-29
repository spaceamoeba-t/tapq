import Foundation
import TapQContracts

/// One line of an agent session's transcript, parsed into the parts a question can be
/// answered from.
///
/// Unlike every other type in this module, this one **may** carry tool input and tool
/// output. That is the transcript decision (ratified 2026-08-28,
/// `docs/TRANSCRIPT_CONTEXT_PLAN.md`): under a cloud voice backend TapQ may *read* an
/// agent's full session and answer questions from it. The redaction contract is not
/// weakened, it is scoped — it remains the rule for local surfaces, for event memory, and
/// for anything TapQ says unprompted. Nothing here is ever spoken; only the answer model's
/// reply is, and only in answer to a question the wearer asked.
public struct TranscriptEntry: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
        /// A tool result carried back to the agent.
        case toolResult = "tool_result"
        /// A line whose `type` this build does not model — a summary, a system note.
        /// Carried rather than dropped: it is still session history.
        case other
    }

    public let role: Role
    /// The line's prose, with content blocks joined. Empty for a pure tool call.
    public let text: String
    /// The tool the assistant asked for, when this line is a tool use.
    public let toolName: String?
    /// The tool's arguments, as the JSON text the agent wrote.
    public let toolInput: String?
    /// The tool's output, as the agent received it.
    public let toolOutput: String?
    public let timestamp: Date?

    public init(
        role: Role,
        text: String,
        toolName: String? = nil,
        toolInput: String? = nil,
        toolOutput: String? = nil,
        timestamp: Date? = nil
    ) {
        self.role = role
        self.text = text
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.timestamp = timestamp
    }

    /// The entry as one block of the answer model's input.
    public var rendered: String {
        var parts: [String] = []
        switch role {
        case .user: parts.append("[user]")
        case .assistant: parts.append("[assistant]")
        case .toolResult: parts.append("[tool result]")
        case .other: parts.append("[note]")
        }
        if let toolName, !toolName.isEmpty { parts.append("tool: \(toolName)") }
        if !text.isEmpty { parts.append(text) }
        if let toolInput, !toolInput.isEmpty { parts.append("input: \(toolInput)") }
        if let toolOutput, !toolOutput.isEmpty { parts.append("output: \(toolOutput)") }
        return parts.joined(separator: "\n")
    }

    /// Everything a relevance score reads, lowercased once.
    var searchText: String {
        ([text, toolName ?? "", toolInput ?? "", toolOutput ?? ""])
            .joined(separator: " ")
            .lowercased()
    }

    var length: Int { rendered.count }
}

/// Why a session's transcript could not be read.
public enum TranscriptUnavailability: String, Error, Sendable, Equatable {
    /// No hook has told TapQ where this session's transcript is. Every path the shim
    /// forwards is optional, and a peer too old to send one lands here.
    case notAttached = "not_attached"
    /// The path was forwarded but nothing can be opened at it — deleted, moved, or on a
    /// volume this process cannot read.
    case unreadable
    /// The file opened but no line in it parsed.
    case empty
}

/// The transcripts of the agent sessions this runtime is serving, tailed incrementally.
///
/// ## What is stored, and for how long
///
/// TapQ persists **nothing**: the agent's own transcript file is the store. What is held
/// here is a byte offset per session and a bounded in-memory tail of parsed entries, and
/// both die with the runtime. That is the whole storage design from
/// `docs/TRANSCRIPT_CONTEXT_PLAN.md`, and it is why a `tapq memory clear` has nothing to do
/// here — there is nothing of the agent's that TapQ kept.
///
/// ## Tolerating a file that rewrites itself
///
/// Claude Code compacts sessions, which rewrites the transcript in place. Two things
/// therefore cannot be assumed: that the file only grows, and that an offset taken before a
/// rewrite still points at the same conversation. So every read checks both — a file
/// shorter than the offset, and an offset that is not immediately after a newline — and
/// re-syncs from the top when either fails. Re-syncing is cheap and losing the tail is not,
/// so the check is unconditional rather than a recovery path.
@MainActor public final class TranscriptStore {
    /// How many parsed entries a session keeps in memory. A generous tail: the answer path
    /// caps by characters, not entries, and re-reading from disk for a question that could
    /// have been answered from memory is the expensive mistake.
    public nonisolated static let defaultTailEntryLimit = 400
    /// The most that is read from disk in one go. A tail longer than this means the file
    /// grew by megabytes between reads (a compaction, or a first attach to a long session);
    /// the read then starts at the last window rather than parsing the whole history.
    public nonisolated static let defaultReadWindowBytes = 4 * 1024 * 1024
    /// How often `transcript.tailed` is emitted, in reads per line. Tailing happens on every
    /// hook event, and a log line per approval would drown the file it is in.
    static let tailDiagnosticEvery = 20

    private struct Session {
        var path: String
        var offset: UInt64 = 0
        var entries: [TranscriptEntry] = []
        var reads = 0
        var malformedLines = 0
    }

    private var sessions: [String: Session] = [:]
    private let tailEntryLimit: Int
    private let readWindowBytes: Int
    private let diagnostics: TapQDiagnosticEmitter

    public init(
        tailEntryLimit: Int = TranscriptStore.defaultTailEntryLimit,
        readWindowBytes: Int = TranscriptStore.defaultReadWindowBytes,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.tailEntryLimit = max(1, tailEntryLimit)
        self.readWindowBytes = max(1024, readWindowBytes)
        self.diagnostics = TapQDiagnosticEmitter(category: "Transcript", sink: diagnosticSink)
    }

    /// Sessions TapQ has been told the transcript path for. For diagnostics and tests.
    public var attachedSessions: [String] { sessions.keys.sorted() }

    public func path(session: String) -> String? { sessions[session]?.path }

    /// Records where a session's transcript lives, and reads whatever is already in it.
    ///
    /// Idempotent for the same path — every hook event carries it, so this is called
    /// constantly — and a *different* path for a known session resets the offset and the
    /// tail, because it is a different file and an offset into the old one means nothing.
    public func attach(session: String, path: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, !path.isEmpty else { return }
        if let existing = sessions[session] {
            guard existing.path != path else {
                tail(session: session)
                return
            }
            diagnostics.record("transcript.reattached", fields: ["session": Self.tag(session)])
        }
        sessions[session] = Session(path: path)
        diagnostics.record("transcript.attached", fields: ["session": Self.tag(session)])
        tail(session: session)
    }

    /// Reads whatever has been appended since the last read.
    @discardableResult
    public func tail(session: String) -> Int {
        guard var state = sessions[session] else { return 0 }
        guard let handle = FileHandle(forReadingAtPath: state.path) else {
            diagnostics.record("transcript.unavailable", level: .error, fields: [
                "session": Self.tag(session),
                "reason": TranscriptUnavailability.unreadable.rawValue,
            ])
            return 0
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return 0 }

        var start = state.offset
        var resynced: String?
        if size < state.offset {
            // The file shrank: compaction rewrote it, or the session was restarted onto the
            // same path. Everything held is about a conversation that no longer exists.
            resynced = "truncated"
            start = 0
            state.entries.removeAll()
        } else if state.offset > 0, !Self.endsALine(handle, before: state.offset) {
            // The offset survived the size check but no longer sits after a newline, so it
            // is pointing into the middle of a line of some *other* content. A rewrite that
            // happened to leave the file longer looks exactly like this.
            resynced = "offset_invalid"
            start = 0
            state.entries.removeAll()
        }
        if size - start > UInt64(readWindowBytes) {
            // Far behind: read the last window and give up on the gap rather than parsing
            // megabytes at a turn boundary. Starting mid-line is harmless — the fragment
            // fails to parse and is counted.
            start = size - UInt64(readWindowBytes)
            if resynced == nil { resynced = "window_clamped" }
        }
        guard start <= size, (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else {
            state.offset = size
            sessions[session] = state
            return 0
        }

        let (entries, malformed, consumed) = Self.parse(data)
        state.offset = start + UInt64(consumed)
        state.malformedLines += malformed
        state.entries.append(contentsOf: entries)
        if state.entries.count > tailEntryLimit {
            state.entries.removeFirst(state.entries.count - tailEntryLimit)
        }
        state.reads += 1
        sessions[session] = state

        if let resynced {
            diagnostics.record("transcript.resynced", level: .warning, fields: [
                "session": Self.tag(session), "reason": resynced,
            ])
        }
        // Throttled: every hook event tails, and one line per approval would swamp the log.
        if !entries.isEmpty, state.reads % Self.tailDiagnosticEvery == 1 {
            diagnostics.record("transcript.tailed", level: .debug, fields: [
                "session": Self.tag(session),
                "bytes": "\(consumed)",
                "entries": "\(entries.count)",
                "malformed": "\(malformed)",
            ])
        }
        return entries.count
    }

    /// The session's in-memory tail, oldest first, after reading anything new.
    ///
    /// This is the "on-demand re-read" seam: the caller asks at question time, the store
    /// reads whatever the agent wrote since the last hook event, and the answer is composed
    /// from a tail that is current rather than from whatever happened to be cached.
    public func entries(session: String) -> Result<[TranscriptEntry], TranscriptUnavailability> {
        guard let state = sessions[session] else { return .failure(.notAttached) }
        guard FileManager.default.isReadableFile(atPath: state.path) else {
            diagnostics.record("transcript.unavailable", level: .error, fields: [
                "session": Self.tag(session),
                "reason": TranscriptUnavailability.unreadable.rawValue,
            ])
            return .failure(.unreadable)
        }
        tail(session: session)
        let entries = sessions[session]?.entries ?? []
        guard !entries.isEmpty else {
            diagnostics.record("transcript.unavailable", level: .error, fields: [
                "session": Self.tag(session),
                "reason": TranscriptUnavailability.empty.rawValue,
            ])
            return .failure(.empty)
        }
        return .success(entries)
    }

    /// How many entries a session's in-memory tail holds. A caller that has been handed
    /// exactly this many knows there may be older history on disk, which is the one thing it
    /// needs in order to decide whether ``reread(session:bytes:)`` is worth a file read.
    public var tailLimit: Int { tailEntryLimit }

    /// Re-reads a wider window straight off disk, without touching the checkpoint or the
    /// in-memory tail.
    ///
    /// The tail is bounded so a session that runs all day does not become a heap the runtime
    /// carries around; this is the other half of that bargain. A question whose answer is
    /// older than the tail — "what did you decide about the migration, two hundred tool calls
    /// ago?" — is answered by going back to the file, which is the store TapQ never had to
    /// keep a copy of.
    ///
    /// Bounded by `bytes` for the same reason the incremental read is: parsing an entire
    /// long session at a turn boundary is a timeout, not a better answer.
    public func reread(
        session: String,
        bytes: Int? = nil
    ) -> Result<[TranscriptEntry], TranscriptUnavailability> {
        guard let state = sessions[session] else { return .failure(.notAttached) }
        guard let handle = FileHandle(forReadingAtPath: state.path) else {
            diagnostics.record("transcript.unavailable", level: .error, fields: [
                "session": Self.tag(session),
                "reason": TranscriptUnavailability.unreadable.rawValue,
            ])
            return .failure(.unreadable)
        }
        defer { try? handle.close() }
        let window = UInt64(max(1024, bytes ?? readWindowBytes))
        guard let size = try? handle.seekToEnd() else { return .failure(.unreadable) }
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else {
            return .failure(.empty)
        }
        let (entries, malformed, _) = Self.parse(data)
        guard !entries.isEmpty else { return .failure(.empty) }
        diagnostics.record("transcript.reread", level: .debug, fields: [
            "session": Self.tag(session),
            "bytes": "\(data.count)",
            "entries": "\(entries.count)",
            "malformed": "\(malformed)",
        ])
        return .success(entries)
    }

    /// The one session to answer about when the caller named no agent: the session that has
    /// most recently been tailed. With one agent connected — the shipping case — there is
    /// no other candidate, and with several the caller is expected to resolve the name
    /// first.
    public func mostRecentlyActiveSession() -> String? {
        sessions.max { ($0.value.reads, $0.key) < ($1.value.reads, $1.key) }?.key
    }

    /// Forgets a session. Called when a run ends; nothing on disk is touched.
    public func detach(session: String) {
        sessions.removeValue(forKey: session)
    }

    // MARK: - Parsing

    /// Parses whole lines out of `data`, returning the entries, the count of lines nothing
    /// was kept from, and how many bytes were consumed.
    ///
    /// "Nothing kept" covers both a line that is not JSON and a line that is JSON but
    /// carries no prose, no tool call, and no tool output — a bare summary record, a hook
    /// marker. Both are reported under `malformed` because from the answer's side they are
    /// the same fact: that many lines of the file contributed nothing.
    ///
    /// A trailing partial line is deliberately *not* consumed: the agent writes lines
    /// atomically but a read can land mid-write, and re-reading those bytes next time is
    /// how a half-written line becomes a whole one instead of a permanent parse failure.
    static func parse(_ data: Data) -> (entries: [TranscriptEntry], malformed: Int, consumed: Int) {
        var entries: [TranscriptEntry] = []
        var malformed = 0
        var consumed = 0
        var lineStart = data.startIndex
        for index in data.indices where data[index] == UInt8(ascii: "\n") {
            let line = data[lineStart..<index]
            consumed = data.distance(from: data.startIndex, to: index) + 1
            lineStart = data.index(after: index)
            guard !line.isEmpty else { continue }
            if let entry = parseLine(Data(line)) {
                entries.append(entry)
            } else {
                malformed += 1
            }
        }
        return (entries, malformed, consumed)
    }

    /// Claude Code's JSONL: one object per line, `type` naming the speaker and `message`
    /// carrying either a string or an array of content blocks.
    static func parseLine(_ data: Data) -> TranscriptEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let type = (object["type"] as? String) ?? ""
        let message = object["message"] as? [String: Any]
        let timestamp = (object["timestamp"] as? String).flatMap(Self.parseTimestamp)

        var texts: [String] = []
        var toolName: String?
        var toolInput: String?
        var toolOutput: String?

        if let content = message?["content"] as? String {
            texts.append(content)
        } else if let blocks = message?["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                case "tool_use":
                    toolName = block["name"] as? String
                    if let input = block["input"],
                       let encoded = try? JSONSerialization.data(withJSONObject: input) {
                        toolInput = String(decoding: encoded, as: UTF8.self)
                    }
                case "tool_result":
                    toolOutput = Self.flatten(block["content"])
                default:
                    break
                }
            }
        }

        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let role: TranscriptEntry.Role
        switch type {
        case "assistant": role = .assistant
        case "user": role = toolOutput == nil ? .user : .toolResult
        case "": return nil
        default: role = .other
        }
        // A line with nothing in any of the four fields carries no history — a bare
        // `summary` record, a hook marker — and would only spend the answer's character cap.
        guard !text.isEmpty || toolName != nil || toolOutput != nil else { return nil }
        return TranscriptEntry(
            role: role,
            text: text,
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: toolOutput,
            timestamp: timestamp
        )
    }

    /// Tool results arrive as a string, as content blocks, or as something else entirely.
    private static func flatten(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        if let content, let encoded = try? JSONSerialization.data(withJSONObject: content) {
            return String(decoding: encoded, as: UTF8.self)
        }
        return nil
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ text: String) -> Date? {
        timestampFormatter.date(from: text) ?? plainTimestampFormatter.date(from: text)
    }

    /// Whether the byte before `offset` is a newline — the one cheap way to notice that a
    /// rewrite left a stale offset pointing into the middle of a line.
    private static func endsALine(_ handle: FileHandle, before offset: UInt64) -> Bool {
        guard offset > 0, (try? handle.seek(toOffset: offset - 1)) != nil,
              let byte = try? handle.read(upToCount: 1), byte.count == 1 else { return false }
        return byte[byte.startIndex] == UInt8(ascii: "\n")
    }

    /// A session identifier is opaque to the wearer and is never spoken; in a log it is
    /// still an identifier, so only a short prefix goes in a diagnostic field.
    private static func tag(_ session: String) -> String {
        String(session.prefix(8))
    }
}
