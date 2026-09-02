import Foundation
import TapQContracts

/// What kind of thing one durable dialogue entry records.
///
/// A string newtype rather than an `enum`, and that is the whole of the M3 migration
/// story: milestone 3 adds standing directives (`WearerDialogueKind.directive`, one
/// `static let` here plus one recorder), and a file written by that build stays readable
/// by this one — an unrecognized kind decodes into a value that round-trips and renders
/// as itself, instead of failing the line and taking the wearer's history with it. A
/// closed `enum` would have made the same addition a file-format break.
public struct WearerDialogueKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Something the wearer said, as the recognizer finalized it. Stored verbatim
    /// (maintainer-ratified 2026-08-29): wearer utterances are short, and a summary of
    /// "the thing I asked you earlier" is exactly the thing that cannot be recalled.
    public static let wearerSaid = WearerDialogueKind(rawValue: "wearer_said")
    /// A sentence TapQ handed the backend to read aloud — a prompt, a read-back, a
    /// refusal, a narrated boundary — and, since 2026-09-01, a sentence the model composed
    /// and spoke in its own words. One kind for all of them, because from the wearer's
    /// side they are one thing: what TapQ said. Splitting the model's replies into their own
    /// kind was considered and rejected on exactly that ground — a wearer asking "what did
    /// you tell me?" is not asking who drafted it — and the answer would have had to be
    /// rendered by recall anyway, in the same words.
    public static let tapqSaid = WearerDialogueKind(rawValue: "tapq_said")
    /// A resolved approval, selection, or stop question, with the subject it decided.
    public static let decision = WearerDialogueKind(rawValue: "decision")
    /// An instruction that actually reached an agent, in full.
    public static let instruction = WearerDialogueKind(rawValue: "instruction")
    /// A deliberation-loop task (Pillar C, M2): the goal the wearer handed over and how it
    /// ended. Added exactly as this type's doc comment predicted a kind would be — one
    /// `static let` and one recorder — so a file written by this build reads on an M1 binary
    /// and vice versa.
    public static let task = WearerDialogueKind(rawValue: "task")
    /// A one-shot follow-up (M3): the sentence TapQ agreed to act on at a named agent's
    /// next finished boundary, and every step of what became of it. The second addition
    /// made exactly the way this type's doc comment predicted — one `static let` and one
    /// recorder — and the first one made against a *live* older build, which is what the
    /// open rawValue was for: a 2026-08 binary reading this file renders the line as
    /// itself rather than dropping the wearer's month on the floor.
    public static let followup = WearerDialogueKind(rawValue: "followup")
    /// A session event under session focus (`docs/SESSION_FOCUS_PLAN.md` §4): TapQ started
    /// one, the focus moved, a session was detached, a session TapQ started ended. The
    /// third addition made the way this type's doc comment predicted, and the one that
    /// answers "what happened to the test-suite session" tomorrow.
    public static let session = WearerDialogueKind(rawValue: "session")
}

/// The words a session event is recorded under, so the record and its readers agree.
public enum WearerSessionEvent {
    /// TapQ started a session for the goal in `text`.
    public static let started = "started"
    /// The focus moved to a new session, in `text` the goal or "keyboard session".
    public static let focusMoved = "focus moved"
    /// A keyboard session lost the focus and is back on its own terminal.
    public static let detachedToKeyboard = "detached: keyboard"
    /// A session TapQ started lost the focus and is being stopped.
    public static let detachedAndStopped = "detached: stopped"
    /// A session TapQ started has exited.
    public static let ended = "ended"
}

/// One line of the durable record of TapQ's own dialogue with the wearer.
///
/// **Speech-safe by construction, and structurally so.** Every text field here arrives
/// from a surface that was already cleared for speech: `text` is either something the
/// wearer said into the microphone, something TapQ sent to the backend to be read out
/// loud, or the spoken summary of a request — the same three sources
/// ``SessionContextEvent`` draws on. There is nowhere in this type to put a `toolInput`,
/// a `cwd`, or a `permissionMode`, so the redaction guarantee needs no filter and no
/// review: an unsafe field cannot be spelled.
///
/// Optional-looking fields are empty strings rather than `nil`. A JSONL file a person
/// greps reads better with a stable key set, and "no agent" and "the empty agent name"
/// are the same fact.
public struct WearerDialogueEntry: Sendable, Equatable {
    /// Per-entry cap on `text` and `subject`.
    ///
    /// Generous — roughly eighty words, several times what anyone says in one breath —
    /// and present for the reason ``SessionRecall/questionCharacterLimit`` is: a
    /// recognizer that runs away with a nearby conversation must not be able to turn one
    /// utterance into a page of prompt. It does not conflict with
    /// NARRATION_MODEL_PLAN's no-truncation rule, which governs the agent's copy of a
    /// dictated instruction; this is a spoken recall surface, and the same plan already
    /// records `SessionContextStore` capping its own for that reason.
    public static let textCharacterLimit = 480

    public let kind: WearerDialogueKind
    /// When it was said, heard, or resolved, from the store's clock.
    public let timestamp: Date
    /// The utterance, verbatim, or a decision's subject phrase ("swift test").
    public let text: String
    /// The agent's display name ("Claude Code"), never its opaque session identifier.
    /// Empty when the entry is not about one agent.
    public let agentDisplayName: String
    /// How a decision resolved, in the wearer's terms ("approved"). Empty otherwise.
    public let outcome: String
    /// The tool name as the adapter rendered it ("Bash"). Empty otherwise.
    public let toolName: String

    public init(
        kind: WearerDialogueKind,
        timestamp: Date,
        text: String,
        agentDisplayName: String = "",
        outcome: String = "",
        toolName: String = ""
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.text = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(text),
            limit: Self.textCharacterLimit
        )
        self.agentDisplayName = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(agentDisplayName),
            limit: SpokenSummary.sentenceCharacterLimit
        )
        // Capped like `text` and for the same reason: a selection's outcome carries the
        // wearer's own spoken answer ("answered use the staging branch"), so it is a text
        // field wearing a label's name.
        self.outcome = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(outcome),
            limit: Self.textCharacterLimit
        )
        self.toolName = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(toolName),
            limit: SpokenSummary.sentenceCharacterLimit
        )
    }
}

extension WearerDialogueEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case kind
        case text
        case agentDisplayName = "agent"
        case outcome
        case toolName = "tool"
    }

    /// Written by hand rather than synthesized so a line survives the schema growing
    /// around it: every field but `kind` and `ts` is decoded with a default, so an entry
    /// written by an older build (or by a newer one, whose extra keys are ignored) still
    /// reads. This is the other half of ``WearerDialogueKind``'s open rawValue — together
    /// they are what "no migration for M3" means.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stamp = try container.decode(String.self, forKey: .timestamp)
        guard let timestamp = WearerConversationTimestamp.date(from: stamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "Not an ISO 8601 timestamp: \(stamp)"
            )
        }
        self.init(
            kind: try container.decode(WearerDialogueKind.self, forKey: .kind),
            timestamp: timestamp,
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            agentDisplayName: try container.decodeIfPresent(
                String.self, forKey: .agentDisplayName
            ) ?? "",
            outcome: try container.decodeIfPresent(String.self, forKey: .outcome) ?? "",
            toolName: try container.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WearerConversationTimestamp.string(from: timestamp), forKey: .timestamp)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(agentDisplayName, forKey: .agentDisplayName)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(toolName, forKey: .toolName)
    }
}

/// The one timestamp format the durable record is written and read in.
///
/// Fractional seconds so a burst — a prompt, an answer, and a confirmation inside one
/// second — keeps the order it happened in, which is the order the recent window is read
/// back in. Shared by the writer and the reader so a file this build wrote is a file this
/// build can read, which is not automatic when each side builds its own formatter.
enum WearerConversationTimestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

/// TapQ's own memory: the durable, append-only record of the dialogue it has had with the
/// wearer (Pillar A of docs/TAPQ_AGENT_PLAN.md, milestone M1).
///
/// **How this differs from the conversation-memory rung already in the tree.**
/// `SessionContextStore` (and `SessionRecall`, and `ConversationMemory` in `TapQCLI`)
/// remember *the agents' requests*: a bounded in-memory ring, per agent session, holding
/// what each session asked and how it was answered, evicted at sixteen events and eight
/// sessions, gone when the process exits. They answer "what changed in this session?"
/// while a window is open. This store remembers *the conversation*: what the wearer said
/// and what TapQ said back, across sessions, across realtime-session recycles, and across
/// runtime restarts, on disk. They overlap on decisions and instructions by design — a
/// decision is both an event in a session and a thing TapQ and the wearer settled — and
/// nothing reads one to answer the other's question. Neither is a cache of the other.
///
/// **Speech-safe by construction.** The recording API takes spoken text, heard text, and
/// already-spoken decision fields; it takes no request object, no event payload, and no
/// adapter-supplied field. See ``WearerDialogueEntry``.
///
/// **Bounded by rotation, both ways.** Entries older than ``retention`` (30 days,
/// maintainer-ratified 2026-08-29) are dropped, and the file is held under
/// ``maximumBytes``; whichever binds first, binds. Rotation *compacts in place* — the
/// oldest entries are dropped and the survivors rewritten — rather than moving the live
/// file aside the way `AutoAnswerLog` and `ReasonerShadowLog` do. Those two are read by a
/// person after the fact, so a generation moved to `.1.jsonl` is still there to read;
/// this one is read by TapQ *on the next turn*, and a rotation that emptied the live file
/// would erase the wearer's recent history at the exact moment it got interesting.
///
/// **The file is mirrored in memory.** The recent window is read on the per-turn
/// grounding path, immediately before the microphone opens, so it must not touch the
/// disk; the whole file (at most ``maximumBytes``) is loaded once at construction and
/// kept. Disk writes are appends, and a full rewrite only at a rotation.
///
/// **Every file failure is swallowed and diagnosed.** Consistent with the plan's failure
/// posture: a cloud call failing breaks the voice pipe, a local file problem is loud in
/// the log and the session stays alive. TapQ forgetting is not a reason for TapQ to stop
/// listening.
@MainActor public final class WearerConversationStore {
    /// `nonisolated` throughout: these are the store's defaults, and a default argument is
    /// evaluated at the *call site*, which is not on the main actor when a test or a
    /// composition names one.
    public nonisolated static let fileName = "wearer-conversation.jsonl"
    /// 30 days, ratified 2026-08-29 as the retention default.
    public nonisolated static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60
    /// "A few MB", and the smaller of the two bounds in practice: 2 MB is on the order of
    /// ten thousand utterances, which is far more conversation than thirty days holds.
    public nonisolated static let defaultMaximumBytes = 2 * 1_024 * 1_024

    /// After a size rotation the file is left at this fraction of the cap, so the next
    /// append does not rotate again — and the one after that, and the one after that.
    nonisolated static let compactionFraction = 0.75

    private struct Line {
        let entry: WearerDialogueEntry
        /// The encoded byte length, newline included, so the size bound is measured in the
        /// bytes actually on disk rather than in characters.
        let bytes: Int
    }

    public let fileURL: URL
    public let retention: TimeInterval
    public let maximumBytes: Int

    private let clock: @Sendable () -> Date
    private let diagnostics: TapQDiagnosticEmitter
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var lines: [Line] = []
    private var byteCount = 0

    /// - Parameters:
    ///   - directory: the runtime's application-support directory — the same `0700`
    ///     directory the discovery record, the shadow log, and the auto-answer log live
    ///     in. The store never creates it; the runtime has already prepared it, and a
    ///     store that made its own would be a store that wrote outside the runtime's
    ///     permissions.
    ///   - clock: timestamp source, injected by tests.
    ///   - retention: how far back entries are kept.
    ///   - maximumBytes: the live file's ceiling.
    public init(
        directory: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        retention: TimeInterval = defaultRetention,
        maximumBytes: Int = defaultMaximumBytes,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.clock = clock
        self.retention = retention
        self.maximumBytes = maximumBytes
        self.diagnostics = TapQDiagnosticEmitter(
            category: "WearerMemory",
            sink: diagnosticSink
        )
        let encoder = JSONEncoder()
        // The same two options every other JSONL TapQ writes uses: sorted keys so the file
        // is diffable across runs, unescaped slashes so a person reading it sees prose.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        load()
    }

    // MARK: - Recording

    /// Records something the wearer said, verbatim.
    public func recordWearerUtterance(_ text: String) {
        append(.init(kind: .wearerSaid, timestamp: clock(), text: text))
    }

    /// Records a sentence TapQ said to the wearer.
    ///
    /// Called at the moment it goes out to be spoken, not when it was written, so the
    /// record is in the order the wearer heard it — the same discipline the per-turn
    /// grounding already follows.
    public func recordSpokenSentence(_ text: String) {
        append(.init(kind: .tapqSaid, timestamp: clock(), text: text))
    }

    /// Records a resolved decision and what it was about.
    ///
    /// The parameters are the ones TapQ has already said out loud — the agent's display
    /// name, the request's spoken summary, the tool name as the adapter rendered it — and
    /// deliberately not the request itself. A caller cannot hand this an `ApprovalRequest`
    /// and hope the store remembers which of its fields are unspeakable.
    public func recordDecision(
        agentDisplayName: String,
        summary: String,
        outcome: String,
        toolName: String = ""
    ) {
        append(.init(
            kind: .decision,
            timestamp: clock(),
            text: summary,
            agentDisplayName: agentDisplayName,
            outcome: outcome,
            toolName: toolName
        ))
    }

    /// Records an instruction at the moment it reached an agent, in full.
    ///
    /// On delivery rather than on dictation, for the reason
    /// ``SessionContextStore/recordInstruction(session:agent:text:)`` gives: until the
    /// turn boundary comes around a queued instruction may still be dropped at capacity,
    /// and remembering one the agent never received would be inventing a conversation.
    public func recordInstruction(agentDisplayName: String, text: String) {
        append(.init(
            kind: .instruction,
            timestamp: clock(),
            text: text,
            agentDisplayName: agentDisplayName,
            outcome: "delivered"
        ))
    }

    /// Records a deliberation-loop task: what was asked, and how it ended
    /// (`docs/TAPQ_AGENT_PLAN.md`, Pillar C).
    ///
    /// Called twice per task — once at the start with `outcome` `"started"`, once at the end
    /// with the ending — and the pair is the point. A runtime that dies mid-task leaves a
    /// `started` with no ending, which is exactly the honest record: the loop is gone, the
    /// wearer's request is not. "A restart mid-task loses the loop but not the record of
    /// what was asked" is this method and its ordering.
    ///
    /// `goal` is the wearer's own sentence as the realtime model reported it — the same
    /// provenance as ``recordInstruction(agentDisplayName:text:)``'s text, and read back to
    /// them out loud when the task was accepted. There is nothing here a wearer did not say
    /// or hear; internal tool payloads, excerpts, and agent output never reach this store.
    public func recordTask(goal: String, outcome: String) {
        append(.init(
            kind: .task,
            timestamp: clock(),
            text: goal,
            outcome: outcome
        ))
    }

    /// Records one lifecycle event of a one-shot follow-up (`docs/TAPQ_AGENT_PLAN.md`,
    /// "Initiative (M3, the guarded step)").
    ///
    /// Called for every step a follow-up takes — set, replaced, cancelled, aborted in its
    /// announce grace, expired with the runtime, fired with the outcome of its review — so
    /// that a wearer who asks tomorrow can find out both that TapQ agreed to something and
    /// what came of it. The follow-up itself lives only in memory
    /// (``WearerFollowupBook``), which is exactly why the record has to be complete: this
    /// file is the only place a follow-up that expired with the process leaves a trace.
    ///
    /// `instruction` is the wearer's own sentence, read back to them out loud when TapQ
    /// noted it — the same provenance as a dictated instruction's text. `event` is one of
    /// the words in ``WearerFollowupEvent``. Nothing an agent wrote reaches this store;
    /// boundary summaries are read by the review model and go no further.
    public func recordFollowup(agentDisplayName: String, instruction: String, event: String) {
        append(.init(
            kind: .followup,
            timestamp: clock(),
            text: instruction,
            agentDisplayName: agentDisplayName,
            outcome: event
        ))
    }

    /// Records one session event under session focus (`docs/SESSION_FOCUS_PLAN.md` §4).
    ///
    /// `text` is the goal TapQ read back when it started the session, or a short phrase
    /// for a session that has none ("keyboard session"); `event` is one of the words in
    /// ``WearerSessionEvent``. Never a session identifier, never a directory: the session
    /// book beside this file (`sessions.jsonl`) carries those, and nothing reads that book
    /// into speech.
    public func recordSession(agentDisplayName: String, text: String, event: String) {
        append(.init(
            kind: .session,
            timestamp: clock(),
            text: text,
            agentDisplayName: agentDisplayName,
            outcome: event
        ))
    }

    /// Appends an already-built entry. The seam every recorder above goes through, and the
    /// one an M3 directive recorder will go through unchanged.
    public func append(_ entry: WearerDialogueEntry) {
        guard !entry.text.isEmpty || !entry.outcome.isEmpty else {
            diagnostics.record("append.skipped", fields: ["reason": "empty"])
            return
        }
        guard let line = encoded(entry) else { return }
        lines.append(Line(entry: entry, bytes: line.count))
        byteCount += line.count
        if enforceBounds() {
            // A rotation has already rewritten the file, this entry included.
            return
        }
        appendToFile(line)
    }

    // MARK: - Reading

    /// Every retained entry, oldest first.
    public func entries() -> [WearerDialogueEntry] {
        lines.map(\.entry)
    }

    /// The newest entries, oldest first, bounded by both a count and a character budget.
    ///
    /// Two bounds because they fail differently: a count keeps the window from being a
    /// transcript, and a character budget keeps a handful of long utterances from
    /// spending the whole prompt. The character budget is applied from the newest end
    /// backwards, so what survives is always the most recent thing said — the entries the
    /// wearer is most likely to mean by "earlier".
    public func recentWindow(
        limit: Int = WearerConversationRecall.windowEntryLimit,
        characterBudget: Int = WearerConversationRecall.windowCharacterLimit
    ) -> [WearerDialogueEntry] {
        guard limit > 0, characterBudget > 0 else { return [] }
        var window: [WearerDialogueEntry] = []
        var spent = 0
        for line in lines.suffix(limit).reversed() {
            let cost = WearerConversationRecall.line(for: line.entry).count
            if spent + cost > characterBudget { break }
            spent += cost
            window.append(line.entry)
        }
        return window.reversed()
    }

    /// The bytes the live file currently holds, as the store accounts for them. For tests
    /// and diagnostics.
    public var storedByteCount: Int { byteCount }

    // MARK: - Clearing

    /// Wipes the record: the file and everything held in memory. `tapq memory clear`.
    ///
    /// - Returns: whether there was a file to remove, so the command can tell the user
    ///   "cleared" from "there was nothing there" rather than claiming both.
    @discardableResult
    public func clear() -> Bool {
        lines.removeAll()
        byteCount = 0
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        do {
            try fileManager.removeItem(at: fileURL)
            diagnostics.record("cleared")
            return true
        } catch {
            diagnostics.record("clear_failed", level: .warning, fields: [
                "error": String(describing: error),
            ])
            return false
        }
    }

    // MARK: - Bounds

    /// Drops what neither bound allows and rewrites the file when anything went.
    ///
    /// - Returns: whether a rewrite happened, which tells ``append(_:)`` its line is
    ///   already on disk.
    private func enforceBounds() -> Bool {
        let cutoff = clock().addingTimeInterval(-retention)
        let kept = lines.drop { $0.entry.timestamp < cutoff }
        var survivors = Array(kept)
        let expired = lines.count - survivors.count

        var overflowed = 0
        if survivors.reduce(0, { $0 + $1.bytes }) > maximumBytes {
            // Compact past the cap rather than to it, so the next append does not rotate
            // again — and the several thousand after it do not either.
            let target = Int(Double(maximumBytes) * Self.compactionFraction)
            var total = survivors.reduce(0) { $0 + $1.bytes }
            // Never the last one. A single entry larger than the cap is not a reason to
            // forget the thing the wearer just said — the file is a couple of megabytes
            // and an entry is at most a few hundred characters, so this is a guard against
            // a pathological configuration rather than against traffic.
            while total > target, survivors.count > 1 {
                total -= survivors.removeFirst().bytes
                overflowed += 1
            }
        }

        guard expired > 0 || overflowed > 0 else { return false }
        lines = survivors
        byteCount = survivors.reduce(0) { $0 + $1.bytes }
        diagnostics.record("rotated", fields: [
            "expired": "\(expired)",
            "overflowed": "\(overflowed)",
            "kept": "\(survivors.count)",
        ])
        rewriteFile()
        return true
    }

    // MARK: - File

    private func encoded(_ entry: WearerDialogueEntry) -> Data? {
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            return line
        } catch {
            diagnostics.record("encode_failed", level: .warning, fields: [
                "error": String(describing: error),
            ])
            return nil
        }
    }

    /// Reads the file into memory once, at construction, and applies both bounds to what
    /// it found — so a runtime restarting after a fortnight away starts with the file
    /// already pruned rather than pruning it at the first thing the wearer says.
    private func load() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            diagnostics.record("load_failed", level: .warning, fields: [
                "reason": "unreadable",
                "path": fileURL.path,
            ])
            return
        }
        var skipped = 0
        for raw in data.split(separator: 0x0A) {
            let line = Data(raw)
            guard !line.isEmpty else { continue }
            guard let entry = try? decoder.decode(WearerDialogueEntry.self, from: line) else {
                // A torn last line after a crash, or a line from a build that changed the
                // format incompatibly. One bad line is not a reason to forget the wearer's
                // month, so it is counted and stepped over.
                skipped += 1
                continue
            }
            lines.append(Line(entry: entry, bytes: line.count + 1))
        }
        byteCount = lines.reduce(0) { $0 + $1.bytes }
        diagnostics.record("loaded", fields: [
            "entries": "\(lines.count)",
            "skipped": "\(skipped)",
            "bytes": "\(byteCount)",
        ])
        // A rewrite here also drops the unreadable lines, which is the only way they ever
        // leave the file.
        if !enforceBounds(), skipped > 0 {
            rewriteFile()
        }
    }

    private func appendToFile(_ line: Data) {
        let fileManager = FileManager.default
        do {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: line,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            diagnostics.record("write_failed", level: .warning, fields: [
                "error": String(describing: error),
            ])
        }
    }

    /// Rewrites the whole file from what is held in memory, atomically.
    ///
    /// `Data.write(options: .atomic)` rather than a hand-rolled temp-and-move: a rotation
    /// that crashed halfway would otherwise leave a truncated file where the wearer's
    /// history was.
    private func rewriteFile() {
        var data = Data()
        for line in lines {
            guard let encoded = encoded(line.entry) else { continue }
            data.append(encoded)
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            diagnostics.record("rewrite_failed", level: .warning, fields: [
                "error": String(describing: error),
            ])
        }
    }
}
