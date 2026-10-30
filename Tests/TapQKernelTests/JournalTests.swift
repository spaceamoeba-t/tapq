import Foundation
import XCTest
import TapQContracts
@testable import TapQKernel

/// The journal's line format (§3.5) and the file behind it (§4.8).
@MainActor
final class JournalTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func line(_ entry: JournalEntry, seq: Int = 3) throws -> String {
        let data = try KernelJSON.encoder().encode(JournalRecord(seq: seq, atMillis: 1_700_000_000_123, entry: entry))
        return String(decoding: data, as: UTF8.self)
    }

    func testTheLineEncodingIsPinned() async throws {
        XCTAssertEqual(try line(.heard(itemID: "item_1", agent: .claude, text: "run the tests")),
                       #"{"agent":"claude","at":1700000000123,"e":"heard","item":"item_1","seq":3,"text":"run the tests"}"#)
        XCTAssertEqual(try line(.decided(itemID: "item_1", intent: .instruct(text: "run the tests"))),
                       #"{"at":1700000000123,"e":"decided","intent":{"instruct":{"text":"run the tests"}},"item":"item_1","seq":3}"#)
        // 2026-10-12: an utterance the intent model routes is heard without an agent, and its
        // decision names the agent.
        XCTAssertEqual(try line(.heard(itemID: "item_2", agent: nil, text: "what is Claude doing?")),
                       #"{"at":1700000000123,"e":"heard","item":"item_2","seq":3,"text":"what is Claude doing?"}"#)
        XCTAssertEqual(try line(.decided(itemID: "item_2", agent: .claude, intent: .status)),
                       #"{"agent":"claude","at":1700000000123,"e":"decided","intent":{"status":{}},"item":"item_2","seq":3}"#)
        XCTAssertEqual(try line(.refused(itemID: "item_3", reason: .consentByMention)),
                       #"{"at":1700000000123,"e":"refused","item":"item_3","reason":"consentByMention","seq":3}"#)
        XCTAssertEqual(try line(.refused(itemID: "p1", reason: .unreadable)),
                       #"{"at":1700000000123,"e":"refused","item":"p1","reason":"unreadable","seq":3}"#)
        XCTAssertEqual(try line(.launchAsked(agent: .codex, requestID: "launch-3", folder: "tapq",
                                             resume: true, held: "lint")),
                       #"{"agent":"codex","at":1700000000123,"e":"launchAsked","folder":"tapq","held":"lint","requestID":"launch-3","resume":true,"seq":3}"#)
        // 2026-10-12: a switch names its conversation, a new one says so; `.saved` writes nothing.
        XCTAssertEqual(try line(.launchAsked(agent: .claude, requestID: "launch-4", folder: "tapq", resume: true,
                                             held: "", target: .conversation(id: "s2"))),
                       #"{"agent":"claude","at":1700000000123,"e":"launchAsked","folder":"tapq","held":"","requestID":"launch-4","resume":true,"seq":3,"target":{"conversation":{"id":"s2"}}}"#)
        XCTAssertEqual(try line(.launchAsked(agent: .codex, requestID: "launch-5", folder: "tapq", resume: false,
                                             held: "lint", target: .new)),
                       #"{"agent":"codex","at":1700000000123,"e":"launchAsked","folder":"tapq","held":"lint","requestID":"launch-5","resume":false,"seq":3,"target":{"new":{}}}"#)
        // 2026-10-24: a start without a yes; `.saved` writes no target, the chat an app shows does.
        XCTAssertEqual(try line(.launching(agent: .claude, held: "carry on")),
                       #"{"agent":"claude","at":1700000000123,"e":"launching","held":"carry on","seq":3}"#)
        XCTAssertEqual(try line(.launching(agent: .chatgpt, target: .shown, held: "and of Spain?")),
                       #"{"agent":"chatgpt","at":1700000000123,"e":"launching","held":"and of Spain?","seq":3,"target":{"shown":{}}}"#)
        XCTAssertEqual(try line(.decided(itemID: "item_4", agent: .claude, intent: .switchConversation(number: 2, text: nil))),
                       #"{"agent":"claude","at":1700000000123,"e":"decided","intent":{"switchConversation":{"number":2}},"item":"item_4","seq":3}"#)
        XCTAssertEqual(try line(.refused(itemID: "item_5", reason: .noSuchConversation)),
                       #"{"at":1700000000123,"e":"refused","item":"item_5","reason":"noSuchConversation","seq":3}"#)
        XCTAssertEqual(try line(.refused(itemID: "item_6", reason: .openElsewhere)),
                       #"{"at":1700000000123,"e":"refused","item":"item_6","reason":"openElsewhere","seq":3}"#)
        XCTAssertEqual(try line(.resolved(agent: .claude, requestID: "p1",
                                          decision: .permission(.deny(feedback: "use pnpm")))),
                       #"{"agent":"claude","at":1700000000123,"decision":{"permission":{"_0":{"deny":{"feedback":"use pnpm"}}}},"e":"resolved","requestID":"p1","seq":3}"#)
        XCTAssertEqual(try line(.spoke(id: SpeechID(raw: 9), text: "Okay.")),
                       #"{"at":1700000000123,"e":"spoke","seq":3,"speech":9,"text":"Okay."}"#)
        XCTAssertEqual(try line(.lost(agent: .claude, .request(id: "p1"))),
                       #"{"agent":"claude","at":1700000000123,"e":"lost","lost":{"request":{"id":"p1"}},"seq":3}"#)
    }

    func testEveryEntryRoundTrips() async throws {
        let question = QuestionRequest(id: "q1", questions: [
            Question(key: "k", header: "DB", text: "Which?", options: [QuestionOption(label: "a", description: "x")],
                     multiSelect: true, allowsFreeText: false),
        ])
        let entries: [JournalEntry] = [
            .heard(itemID: "i", agent: .claude, text: "t"),
            .heard(itemID: "j", agent: nil, text: "t"),
            .decided(itemID: "i", intent: .answer(requestID: "q1", answers: [["a"]])),
            .decided(itemID: "j", agent: .codex, intent: .status),
            .decisionFailed(itemID: "i", reason: "timeout"),
            .refused(itemID: "i", reason: .gateClosed),
            .launchAsked(agent: .codex, requestID: "launch-1", folder: "f", resume: false, held: "h"),
            .launchAsked(agent: .claude, requestID: "launch-2", folder: "f", resume: true, held: "",
                         target: .conversation(id: "s2")),
            .launchAsked(agent: .claude, requestID: "launch-3", folder: "f", resume: false, held: "go", target: .new),
            .launching(agent: .claude, held: "go on"),
            .launching(agent: .codex, target: .conversation(id: "t2"), held: "lint"),
            .launching(agent: .chatgpt, target: .shown, held: "and of Spain?"),
            .launching(agent: .claudeChat, target: .new, held: ""),
            .decided(itemID: "k", agent: .claude, intent: .listConversations),
            .decided(itemID: "l", agent: .claude, intent: .moreConversations),
            .decided(itemID: "m", agent: .codex, intent: .switchConversation(number: 3, text: "lint it")),
            .decided(itemID: "n", agent: .codex, intent: .newConversation(text: nil)),
            .refused(itemID: "o", reason: .busy),
            .started(agent: .claude, sessionID: "s"),
            .started(agent: .chatgpt, sessionID: "c", chats: .api),
            .sent(agent: .claude, text: "t"),
            .interruptSent(agent: .codex),
            .resolved(agent: .claude, requestID: "q1", decision: .answers([["a"]])),
            .resolved(agent: .claude, requestID: "launch-1", decision: .launch(yes: true)),
            .permission(agent: .claude, PermissionRequest(
                id: "p1", tool: "Bash", inputJSON: #"{"command":"ls"}"#, command: "ls", paths: ["a"],
                title: "List", reason: "r", alwaysAllow: AlwaysAllowOffer(description: "d", payloadJSON: "[]"))),
            .question(agent: .codex, question),
            .withdrawn(agent: .claude, requestID: "p1"),
            .finished(agent: .claude, text: ""),
            .stopped(agent: .codex),
            .failed(agent: .claude, reason: "overloaded"),
            .summarized(agent: .claude, finishedSeq: 4, summary: "s"),
            .spoke(id: SpeechID(raw: 2), text: "Okay."),
            .lost(agent: .claude, .turn),
        ]
        for (index, entry) in entries.enumerated() {
            let record = JournalRecord(seq: index + 1, atMillis: 5, entry: entry)
            let decoded = try KernelJSON.decoder().decode(JournalRecord.self,
                                                          from: KernelJSON.encoder().encode(record))
            XCTAssertEqual(decoded, record)
        }
    }

    func testAppendsAreLinesThatLoadBackWithSeqContinuing() async throws {
        let store = JournalStore(directory: directory)
        XCTAssertFalse(store.exists)
        let journal = Journal(store: store, now: { Date(timeIntervalSince1970: 1.5) })
        XCTAssertEqual(try journal.load(), [])
        let appended = [try journal.append(.stopped(agent: .claude)),
                        try journal.append(.sent(agent: .codex, text: "line\nbreak"))]

        let reloaded = Journal(store: JournalStore(directory: directory), now: { Date() })
        let records = try reloaded.load()
        XCTAssertEqual(records, appended)
        XCTAssertEqual(records.map(\.atMillis), [1500, 1500])
        XCTAssertEqual(reloaded.lastSeq, 2)
        XCTAssertEqual(try reloaded.append(.stopped(agent: .codex)).seq, 3)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 3)
    }

    func testATornTailIsDroppedAndTruncated() async throws {
        let sink = RecordingSink()
        let store = JournalStore(directory: directory, diagnostics: sink)
        try store.append(JournalRecord(seq: 1, atMillis: 0, entry: .stopped(agent: .claude)))
        let whole = try Data(contentsOf: store.url)
        let handle = try FileHandle(forWritingTo: store.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"at":0,"e":"sto"#.utf8))
        try handle.close()

        XCTAssertEqual(try store.load(), [JournalRecord(seq: 1, atMillis: 0, entry: .stopped(agent: .claude))])
        XCTAssertEqual(try Data(contentsOf: store.url), whole)
        XCTAssertEqual(sink.named("journal.torn_tail_dropped").map(\.fields), [["bytes": "24"]])
    }

    func testInteriorCorruptionThrows() async throws {
        let store = JournalStore(directory: directory)
        try store.append(JournalRecord(seq: 1, atMillis: 0, entry: .stopped(agent: .claude)))
        let handle = try FileHandle(forWritingTo: store.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        try store.append(JournalRecord(seq: 3, atMillis: 0, entry: .stopped(agent: .claude)))

        XCTAssertThrowsError(try store.load()) { error in
            guard case JournalStoreError.corrupt(line: 2, _) = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testAVersionOneTranscriptIsRefused() async throws {
        try Data().write(to: directory.appendingPathComponent("transcript.jsonl"))
        let store = JournalStore(directory: directory)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? JournalStoreError, .olderTranscript)
            XCTAssertEqual("\(error)", "this workspace has a transcript from an older TapQ; clear it")
        }
    }

    func testOtherFilesInTheDirectoryDoNotMakeAJournal() async throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("recordings"),
                                                withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: directory.appendingPathComponent("diagnostics.log"))
        try Data().write(to: directory.appendingPathComponent("kernel.lock"))
        let store = JournalStore(directory: directory)

        XCTAssertFalse(store.exists)
        XCTAssertEqual(try store.load(), [])
    }
}

@MainActor
final class KernelSessionStoreTests: XCTestCase {
    func testSessionIDsRoundTripPerAgent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KernelSessionStore(directory: directory)
        XCTAssertNil(try store.sessionID(for: .claude))

        try store.save("uuid-1", for: .claude)
        try store.save("thread-7", for: .codex)
        try store.save("uuid-2", for: .claude)

        let reread = KernelSessionStore(directory: directory)
        XCTAssertEqual(try reread.sessionID(for: .claude), "uuid-2")
        XCTAssertEqual(try reread.sessionID(for: .codex), "thread-7")
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8),
                       #"{"schemaVersion":2,"sessions":{"claude":"uuid-2","codex":"thread-7"}}"#)
    }

    func testAnotherSchemaThrows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"schemaVersion":1,"sessions":{}}"#.utf8).write(to: url)

        XCTAssertThrowsError(try KernelSessionStore(url: url).sessionID(for: .claude))
    }
}

final class StatusReportTests: XCTestCase {
    func testTheStatusLineEncodingIsPinned() throws {
        let report = StatusReport(
            type: "status", speaking: false, userSpeaking: false, versionOverride: false,
            agents: [StatusReport.Agent(
                agent: .claude, phase: .working, progress: "Bash: swift test", heldReply: true,
                pending: [StatusReport.Pending(id: "p1", kind: .permission,
                                               prompt: "Claude Code wants to run curl x. Allow it?",
                                               inputJSON: #"{"command":"curl x"}"#)])],
            lastHeard: StatusReport.LastHeard(agent: .claude, text: "run the tests", action: "instruct"))
        let line = String(decoding: try KernelJSON.encoder().encode(report), as: UTF8.self)

        XCTAssertEqual(line, #"{"agents":[{"agent":"claude","heldReply":true,"pending":[{"id":"p1","inputJSON":"{\"command\":\"curl x\"}","kind":"permission","played":false,"prompt":"Claude Code wants to run curl x. Allow it?"}],"phase":"working","progress":"Bash: swift test"}],"lastHeard":{"action":"instruct","agent":"claude","text":"run the tests"},"speaking":false,"type":"status","userSpeaking":false,"v":1,"versionOverride":false}"#)
    }

    func testFieldsLeftOutAreAbsent() throws {
        let report = StatusReport(type: "ready", speaking: true, userSpeaking: false, versionOverride: true,
                                  agents: [StatusReport.Agent(agent: .codex, phase: .notInstalled,
                                                              progress: nil, heldReply: false, pending: [])],
                                  lastHeard: nil)
        XCTAssertEqual(String(decoding: try KernelJSON.encoder().encode(report), as: UTF8.self),
                       #"{"agents":[{"agent":"codex","heldReply":false,"pending":[],"phase":"notInstalled"}],"speaking":true,"type":"ready","userSpeaking":false,"v":1,"versionOverride":true}"#)
    }

    /// The tool line's step state (2026-10-19), pinned; a line without it decodes as unknown.
    func testTheToolLinesStateIsEncodedAndOptional() throws {
        let agent = StatusReport.Agent(agent: .claude, phase: .working, progress: "Bash: Run the tests",
                                       progressState: .done, heldReply: false, pending: [])
        let line = String(decoding: try KernelJSON.encoder().encode(agent), as: UTF8.self)
        XCTAssertEqual(line, #"{"agent":"claude","heldReply":false,"pending":[],"phase":"working","progress":"Bash: Run the tests","progressState":"done"}"#)
        XCTAssertEqual(try JSONDecoder().decode(StatusReport.Agent.self, from: Data(line.utf8)), agent)
        let before = try JSONDecoder().decode(StatusReport.Agent.self, from: Data(
            #"{"agent":"claude","heldReply":false,"pending":[],"phase":"working","progress":"Bash: Run the tests"}"#.utf8))
        XCTAssertNil(before.progressState)
    }

    /// A command being described (2026-10-16) is marked, pinned; once described, and in a line
    /// written before the field, it is absent.
    func testACommandBeingDescribedIsMarkedAndOptional() throws {
        let describing = StatusReport.Pending(id: "p1", kind: .permission,
                                              prompt: "Claude Code wants to run curl x. Allow it?",
                                              inputJSON: nil, command: "curl x", describing: true)
        let line = String(decoding: try KernelJSON.encoder().encode(describing), as: UTF8.self)
        XCTAssertEqual(line, #"{"command":"curl x","describing":true,"id":"p1","kind":"permission","played":false,"prompt":"Claude Code wants to run curl x. Allow it?"}"#)
        XCTAssertEqual(try JSONDecoder().decode(StatusReport.Pending.self, from: Data(line.utf8)), describing)

        let described = StatusReport.Pending(id: "p1", kind: .permission, prompt: "Claude Code wants to fetch x. Allow it?",
                                             inputJSON: nil, command: "curl x")
        XCTAssertFalse(String(decoding: try KernelJSON.encoder().encode(described), as: UTF8.self)
            .contains("describing"))
        let before = try JSONDecoder().decode(StatusReport.Pending.self, from: Data(
            #"{"id":"p1","kind":"permission","prompt":"Claude Code wants to fetch x. Allow it?","command":"curl x","played":true}"#.utf8))
        XCTAssertFalse(before.isDescribing)
        XCTAssertNil(before.describing)
    }

    /// An agent's failure and the conversations read (2026-10-12), pinned; a line written
    /// before them decodes with neither.
    func testAFailureAndTheConversationsReadAreEncodedAndOptional() throws {
        let report = StatusReport(
            type: "status", speaking: false, userSpeaking: false,
            agents: [StatusReport.Agent(
                agent: .claude, phase: .none, progress: nil, heldReply: false, pending: [],
                failure: StatusReport.Failure(kind: .exited, sentence: "Claude Code quit unexpectedly."),
                conversations: StatusReport.Conversations(
                    read: [.init(number: 1, title: "fix the README", age: "today", current: true)], more: 2))],
            lastHeard: nil)
        let line = String(decoding: try KernelJSON.encoder().encode(report), as: UTF8.self)
        XCTAssertEqual(line, #"{"agents":[{"agent":"claude","conversations":{"more":2,"read":[{"age":"today","current":true,"number":1,"title":"fix the README"}]},"failure":{"kind":"exited","sentence":"Claude Code quit unexpectedly."},"heldReply":false,"pending":[],"phase":"none"}],"speaking":false,"type":"status","userSpeaking":false,"v":1,"versionOverride":false}"#)
        XCTAssertEqual(try JSONDecoder().decode(StatusReport.self, from: Data(line.utf8)), report)

        let older = try JSONDecoder().decode(StatusReport.self, from: Data(
            #"{"v":1,"type":"status","speaking":false,"userSpeaking":false,"versionOverride":false,"agents":[{"agent":"codex","phase":"idle","heldReply":false,"pending":[]}]}"#.utf8))
        XCTAssertNil(older.agents[0].failure)
        XCTAssertNil(older.agents[0].conversations)
    }

    /// Written only when true (2026-10-12), so every line without it is the line of before.
    func testAConversationOpenElsewhereIsMarkedOnlyWhenItIs() throws {
        let conversations = StatusReport.Conversations(
            read: [.init(number: 1, title: "run the tests", age: "today", current: true),
                   .init(number: 2, title: "Music medley study", age: "today", current: false, openElsewhere: true)],
            more: 0)
        let line = String(decoding: try KernelJSON.encoder().encode(conversations), as: UTF8.self)
        XCTAssertEqual(line, #"{"more":0,"read":[{"age":"today","current":true,"number":1,"title":"run the tests"},{"age":"today","current":false,"number":2,"openElsewhere":true,"title":"Music medley study"}]}"#)
        XCTAssertEqual(try JSONDecoder().decode(StatusReport.Conversations.self, from: Data(line.utf8)), conversations)
    }
}

final class ReconcileTests: XCTestCase {
    private func fold(_ entries: [JournalEntry]) -> Reconciliation {
        Reconcile.fold(entries.enumerated().map { JournalRecord(seq: $0.offset + 1, atMillis: 0, entry: $0.element) })
    }

    func testFinishedWorkIsNotLost() {
        let result = fold([
            .launchAsked(agent: .claude, requestID: "launch-1", folder: "f", resume: false, held: "run it"),
            .resolved(agent: .claude, requestID: "launch-1", decision: .launch(yes: true)),
            .started(agent: .claude, sessionID: "s"),
            .sent(agent: .claude, text: "run it"),
            .spoke(id: SpeechID(raw: 1), text: "Okay."),
            .permission(agent: .claude, .bash("p1", "ls")),
            .resolved(agent: .claude, requestID: "p1", decision: .permission(.allow(always: false))),
            .finished(agent: .claude, text: "Listed."),
            .spoke(id: SpeechID(raw: 2), text: "Claude Code says: Listed."),
            .launchAsked(agent: .codex, requestID: "launch-10", folder: "f", resume: false, held: "lint"),
            .resolved(agent: .codex, requestID: "launch-10", decision: .launch(yes: false)),
        ])
        XCTAssertEqual(result.lost, [])
        XCTAssertEqual(result.sentences, [])
        XCTAssertEqual(result.heldReplies[.claude], HeldReply(seq: 8, text: "Listed."))
        XCTAssertEqual(result.lastSpeechID, 2)
    }

    func testOpenWorkIsLost() {
        let result = fold([
            .sent(agent: .claude, text: "run it"),
            .permission(agent: .claude, .bash("p1", "ls")),
            .launchAsked(agent: .codex, requestID: "launch-3", folder: "f", resume: false, held: "lint"),
        ])
        XCTAssertEqual(result.lost, [
            .lost(agent: .claude, .turn),
            .lost(agent: .claude, .request(id: "p1")),
            .lost(agent: .codex, .request(id: "launch-3")),
        ])
        XCTAssertEqual(result.affected, [.claude: 1, .codex: 0])
    }

    /// V1 P2-2 (a): the held instruction rides on the yes; a crash before its `sent` loses it.
    func testALaunchYesThatNeverSentIsALostTurn() {
        for started: [JournalEntry] in [[], [.started(agent: .codex, sessionID: "t")]] {
            let result = fold([
                .launchAsked(agent: .codex, requestID: "launch-1", folder: "f", resume: false, held: "lint"),
                .resolved(agent: .codex, requestID: "launch-1", decision: .launch(yes: true)),
            ] + started)
            XCTAssertEqual(result.lost, [.lost(agent: .codex, .turn)])
            XCTAssertEqual(result.sentences,
                           ["TapQ restarted. Codex's unfinished task stopped, and nothing was resent."])
        }
    }

    /// A start without a yes (2026-10-24) carries its words as a launch yes does: cut off before
    /// its `sent`, they are a lost turn; with no words, nothing is lost.
    func testAStartWithoutAYesThatNeverSentIsALostTurn() {
        let result = fold([.launching(agent: .codex, target: .new, held: "lint"),
                           .started(agent: .codex, sessionID: "t"),
                           .launching(agent: .claude, target: .new, held: "")])
        XCTAssertEqual(result.lost, [.lost(agent: .codex, .turn)])
        XCTAssertEqual(result.sentences, ["TapQ restarted. Codex's unfinished task stopped, and nothing was resent."])
        XCTAssertEqual(fold([.launching(agent: .codex, held: "lint"), .sent(agent: .codex, text: "lint"),
                             .finished(agent: .codex, text: "Clean.")]).lost, [])
    }

    /// Codex took up a lost task once resumed (live 2026-10-11): said only when the turn had
    /// reached it, not for a launch yes whose instruction was never sent.
    func testALostTurnCodexReceivedSaysItMayBeTakenUpAgain() {
        let result = fold([.sent(agent: .codex, text: "run the check script")])
        XCTAssertEqual(result.delivered, [.codex])
        XCTAssertEqual(result.sentences, ["TapQ restarted. Codex's unfinished task stopped, and nothing was "
                                              + "resent, but Codex may take the task up again when it resumes."])
        let finishedThenRelaunched = fold([
            .sent(agent: .codex, text: "one"), .finished(agent: .codex, text: "Done."),
            .spoke(id: SpeechID(raw: 1), text: "Codex says: Done."),
            .launchAsked(agent: .codex, requestID: "launch-4", folder: "f", resume: true, held: "two"),
            .resolved(agent: .codex, requestID: "launch-4", decision: .launch(yes: true)),
        ])
        XCTAssertEqual(finishedThenRelaunched.delivered, [])
        XCTAssertEqual(finishedThenRelaunched.sentences,
                       ["TapQ restarted. Codex's unfinished task stopped, and nothing was resent."])
    }

    /// V1 P2-2 (b): a reply journaled but never spoken is told, once.
    func testAReplyNeverSpokenIsTold() {
        let tell = "Claude Code has a reply; say: Claude Code, read it all."
        let unheard: [JournalEntry] = [.sent(agent: .claude, text: "t"), .finished(agent: .claude, text: "All green.")]
        XCTAssertEqual(fold(unheard).sentences, [tell])
        XCTAssertEqual(fold(unheard + [.spoke(id: SpeechID(raw: 1), text: tell)]).sentences, [])
        XCTAssertEqual(fold(unheard + [.spoke(id: SpeechID(raw: 1), text: "Claude Code said: All green.")])
            .sentences, [])
        XCTAssertEqual(fold(unheard + [.sent(agent: .claude, text: "again")]).sentences, [
            "TapQ restarted. Claude Code's unfinished task stopped, and nothing was resent. " + tell,
        ])
        XCTAssertEqual(fold([.finished(agent: .claude, text: " ")]).sentences, [], "an empty reply is no reply")

        let long = String(repeating: "a", count: 200)
        let summarized: [JournalEntry] = [
            .finished(agent: .codex, text: long), .summarized(agent: .codex, finishedSeq: 1, summary: "Short."),
        ]
        XCTAssertEqual(fold(summarized).unheardReplies, [.codex])
        XCTAssertEqual(fold(summarized + [.spoke(id: SpeechID(raw: 1), text: "Codex says, in short: Short.")])
            .unheardReplies, [])
        XCTAssertEqual(fold([.finished(agent: .codex, text: long),
                             .spoke(id: SpeechID(raw: 1), text: Sentences.summaryFailed(.codex))]).unheardReplies, [])
    }

    /// A switch with nothing to say opens no turn, so a restart after it has nothing to tell
    /// (2026-10-12).
    func testASwitchWithNoWordsIsNoLostTask() {
        let result = fold([
            .launchAsked(agent: .claude, requestID: "launch-1", folder: "f", resume: true, held: "",
                         target: .conversation(id: "b")),
            .resolved(agent: .claude, requestID: "launch-1", decision: .launch(yes: true)),
            .started(agent: .claude, sessionID: "b"),
        ])
        XCTAssertEqual(result.lost, [])
        XCTAssertEqual(result.sentences, [])
    }

    /// The reply of a conversation the agent left is not held: "read it all" would read the old
    /// one, and a restart would offer it.
    func testTheReplyOfAConversationLeftIsNotHeld() {
        let before: [JournalEntry] = [
            .started(agent: .claude, sessionID: "a"),
            .sent(agent: .claude, text: "t"),
            .finished(agent: .claude, text: "Old reply."),
        ]
        XCTAssertNotNil(fold(before).heldReplies[.claude])
        XCTAssertEqual(fold(before + [.started(agent: .claude, sessionID: "a")]).heldReplies[.claude],
                       HeldReply(seq: 3, text: "Old reply."), "a resume of the same conversation keeps it")
        let switched = fold(before + [.started(agent: .claude, sessionID: "b")])
        XCTAssertNil(switched.heldReplies[.claude])
        XCTAssertEqual(switched.sentences, [], "nor is it offered as unheard")
    }

    func testWhatAnEarlierRestartMarkedLostIsNotLostAgain() {
        let result = fold([
            .sent(agent: .claude, text: "t"),
            .launchAsked(agent: .codex, requestID: "launch-2", folder: "f", resume: false, held: "h"),
            .lost(agent: .claude, .turn),
            .lost(agent: .codex, .request(id: "launch-2")),
        ])
        XCTAssertEqual(result.lost, [])
        XCTAssertEqual(result.affected, [:])
    }
}
