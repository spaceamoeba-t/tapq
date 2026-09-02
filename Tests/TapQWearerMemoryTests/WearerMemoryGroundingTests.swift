import Foundation
import XCTest
import TapQContracts
@testable import TapQContextBaseline
@testable import TapQInteractionBaseline

/// The consumption half of milestone M1: a bounded recent window from TapQ's own memory
/// joins the realtime model's per-turn grounding, so "the thing I asked you earlier"
/// resolves even after the realtime session has been recycled out from under the
/// conversation.
///
/// Two things are pinned here. What the window *reads like* — deterministic, verbatim for
/// the wearer's own words (ratified 2026-08-29) — and where it *lands*: appended to the
/// window brief the provider already sends, and structurally absent on the path with no
/// model to ground.
@MainActor
final class WearerMemoryGroundingTests: XCTestCase {
    /// The smallest duplex backend that can hold a session open and record what it was
    /// told. Everything the grounding path touches, and nothing else.
    private final class RecordingBackend: VoiceBackend {
        let capabilities = VoiceBackendCapabilities(
            supportsBargeIn: true,
            producesAudio: true,
            duplex: true,
            supportsNativeTurnDetection: true,
            supportsToolCalling: true
        )

        private(set) var instructions: [String] = []
        private(set) var scriptedSpeech: [String] = []
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            handler = onEvent
        }

        func close() {}
        func beginUserTurn() {}

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool { expectingResponse }

        func sendAudio(_ chunk: VoiceAudioChunk) {}
        func requestResponse(text: String) {}

        func requestScriptedSpeech(text: String) {
            scriptedSpeech.append(text)
        }

        func cancelResponse() {}
        func setNativeTurnDetection(_ enabled: Bool) {}
        func declareTools(_ tools: [VoiceToolDeclaration]) {}

        func updateInstructions(_ instructions: String) {
            self.instructions.append(instructions)
        }

        @discardableResult
        func requestModelTurn() -> Bool { true }

        func sendToolResult(callID: String, output: String) {}

        func emit(_ event: VoiceBackendEvent) {
            handler?(event)
        }
    }

    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-grounding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Rendering

    /// The wearer's own words are quoted and unaltered. The quotation marks are not
    /// decoration: they are what tells the model that the words inside are the wearer's
    /// and not TapQ describing them.
    func testWearerUtterancesAreQuotedVerbatim() async {
        let store = makeStore()
        store.recordWearerUtterance("tell Codex to rebase onto main, not merge")

        guard let grounding = WearerConversationRecall.grounding(
            for: store.recentWindow()
        ) else {
            return XCTFail("no grounding for a non-empty memory")
        }
        XCTAssertTrue(
            grounding.contains("Wearer: \"tell Codex to rebase onto main, not merge\""),
            grounding
        )
        XCTAssertTrue(grounding.hasPrefix(WearerConversationRecall.heading), grounding)
    }

    /// Every kind reads as the thing it was, numbered in the order it happened.
    func testTheWindowRendersEachKindInOrder() async {
        let store = makeStore()
        store.recordWearerUtterance("run the tests")
        store.recordSpokenSentence("Claude Code wants to run swift test.")
        store.recordDecision(
            agentDisplayName: "Claude Code",
            summary: "swift test",
            outcome: "approved",
            toolName: "Bash"
        )
        store.recordInstruction(agentDisplayName: "Codex", text: "rerun the failing suite")

        let lines = WearerConversationRecall
            .grounding(for: store.recentWindow())?
            .split(separator: "\n")
            .map(String.init) ?? []
        XCTAssertEqual(Array(lines.suffix(4)), [
            "  1. Wearer: \"run the tests\"",
            "  2. TapQ: Claude Code wants to run swift test.",
            "  3. Decision: approved Bash for Claude Code: swift test",
            "  4. TapQ told Codex: rerun the failing suite",
        ])
    }

    /// An M3 standing directive read by an M1 binary renders as itself rather than being
    /// dropped: a line the model can read beats a hole in the history, and dropping it
    /// would make the numbering lie about what is in the file.
    func testAnUnknownKindStillRenders() async {
        let entry = WearerDialogueEntry(
            kind: WearerDialogueKind(rawValue: "directive"),
            timestamp: start,
            text: "watch the build and tell me if it fails"
        )
        XCTAssertEqual(
            WearerConversationRecall.line(for: entry),
            "directive: watch the build and tell me if it fails"
        )
    }

    /// A follow-up entry names the agent and the lifecycle word, so "what happened to my
    /// follow-up?" is answerable from the window alone: a `created` with nothing after it
    /// is still armed, and a `fired` or `cancelled` says how the promise ended.
    func testAFollowupEntryNamesTheAgentAndTheEvent() async {
        let entry = WearerDialogueEntry(
            kind: .followup,
            timestamp: start,
            text: "rerun the tests",
            agentDisplayName: "Claude Code",
            outcome: "created"
        )
        XCTAssertEqual(
            WearerConversationRecall.line(for: entry),
            "Follow-up on Claude Code (created): rerun the tests"
        )
    }

    /// No history, no line. The per-turn grounding already says what TapQ has said since
    /// the last window; a sentence announcing an empty memory would spend prompt on the
    /// absence of a fact.
    func testAnEmptyMemoryContributesNothing() async {
        XCTAssertNil(WearerConversationRecall.grounding(for: []))
        XCTAssertNil(WearerConversationRecall.grounding(for: makeStore().recentWindow()))
    }

    // MARK: - The join

    /// The window lands in the brief the provider sends immediately before the microphone
    /// opens, after the open-window line and the agent names — the open question stays the
    /// last thing the model reads about *now*, with the history behind it.
    func testTheRecentWindowJoinsThePerTurnGrounding() async {
        let store = makeStore()
        store.recordWearerUtterance("remind me what I asked Codex for")

        let backend = RecordingBackend()
        let provider = makeProvider(backend, intentSource: .modelToolCalls)
        provider.wearerMemoryGrounding = {
            WearerConversationRecall.grounding(for: store.recentWindow())
        }

        provider.start { _ in }
        await settle()

        guard let grounding = backend.instructions.last else {
            return XCTFail("no grounding was sent")
        }
        XCTAssertTrue(grounding.contains("A TapQ window is open"), grounding)
        XCTAssertTrue(
            grounding.contains("Wearer: \"remind me what I asked Codex for\""),
            grounding
        )
        // Order: the window brief first, TapQ's own history last.
        let brief = grounding.range(of: "A TapQ window is open")
        let memory = grounding.range(of: WearerConversationRecall.heading)
        XCTAssertNotNil(brief)
        XCTAssertNotNil(memory)
        if let brief, let memory {
            XCTAssertTrue(brief.lowerBound < memory.lowerBound, grounding)
        }
    }

    /// Every sentence TapQ hands the backend is recorded at the moment it goes out, so the
    /// memory is in the order the wearer heard it.
    func testSpokenSentencesReachTheStoreAsTheyGoOut() async {
        let store = makeStore()
        let backend = RecordingBackend()
        let provider = makeProvider(backend, intentSource: .modelToolCalls)
        provider.onSpokenToWearer = { store.recordSpokenSentence($0) }

        provider.speakScripted("Run the migration? Nod or say yes.")
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, ["Run the migration? Nod or say yes."])
        XCTAssertEqual(store.entries().map(\.text), ["Run the migration? Nod or say yes."])
        XCTAssertEqual(store.entries().map(\.kind), [.tapqSaid])
    }

    /// The other half of the record, and it was missing until 2026-09-01. TapQ only ever
    /// recorded sentences it *wrote*, because handing one over was the only moment there was
    /// to record. An answer the model composed itself had no such moment — so the wearer
    /// could ask about every sentence except the ones they were most likely to be asking
    /// about. The peer's own report of what it said is that moment.
    func testASentenceTheModelComposedReachesTheStore() async {
        let store = makeStore()
        let backend = RecordingBackend()
        let provider = makeProvider(backend, intentSource: .modelToolCalls)
        provider.onSpokenToWearer = { store.recordSpokenSentence($0) }

        provider.start { _ in }
        await settle()
        backend.emit(.spokenByBackend("Windsurf is an AI coding editor from Codeium."))
        await settle()

        XCTAssertEqual(store.entries().map(\.text),
                       ["Windsurf is an AI coding editor from Codeium."])
        XCTAssertEqual(store.entries().map(\.kind), [.tapqSaid],
                       "one kind: from the wearer's side there is one voice saying things")
    }

    /// And not twice. A scripted sentence is filed where TapQ hands it over — the honest
    /// moment for one it wrote — and the peer reads it aloud and reports the transcript like
    /// any other. Recording both would put it in the wearer's history twice, the second time
    /// in the model's own paraphrase of TapQ's punctuation.
    func testAScriptedSentencesTranscriptIsNotRecordedASecondTime() async {
        let store = makeStore()
        let backend = RecordingBackend()
        let provider = makeProvider(backend, intentSource: .modelToolCalls)
        provider.onSpokenToWearer = { store.recordSpokenSentence($0) }

        provider.speakScripted("Run the migration? Nod or say yes.")
        await settle()
        backend.emit(.spokenByBackend("Run the migration, nod or say yes?"))
        await settle()

        XCTAssertEqual(store.entries().map(\.text), ["Run the migration? Nod or say yes."],
                       "the sentence TapQ wrote, once, in the words TapQ wrote it in")
    }

    // MARK: - Scoping

    /// The Apple path neither records nor reads.
    ///
    /// This is the portable half of the guarantee. The composition half — the store is
    /// built only on the `.openaiRealtime` arm of `AppleTapQRuntimeService`, so on the
    /// Apple path there is no object to wire — lives in the host-only runtime target and
    /// is not reachable from a portable test. What *is* provable here is the seam it
    /// leans on: on a transcript-grammar session the recording hook and the memory
    /// grounding are unreachable even when a host wires them, because both sit behind the
    /// provider's existing `.modelToolCalls` guard. A miswiring cannot leak.
    func testTheGrammarPathNeitherRecordsNorGrounds() async {
        let store = makeStore()
        store.recordWearerUtterance("something from an earlier run")
        let recorded = store.entries().count

        let backend = RecordingBackend()
        let provider = makeProvider(backend, intentSource: .transcriptGrammar)
        provider.onSpokenToWearer = { store.recordSpokenSentence($0) }
        provider.wearerMemoryGrounding = {
            WearerConversationRecall.grounding(for: store.recentWindow())
        }

        provider.speakScripted("Run the migration? Nod or say yes.")
        await settle()
        provider.start { _ in }
        await settle()
        backend.emit(.spokenByBackend("a sentence a model composed"))
        await settle()

        XCTAssertEqual(backend.scriptedSpeech, ["Run the migration? Nod or say yes."],
                       "the sentence is still spoken")
        XCTAssertTrue(backend.instructions.isEmpty,
                      "a grammar session is never grounded: \(backend.instructions)")
        XCTAssertEqual(store.entries().count, recorded,
                       "nothing on the grammar path may reach the durable record")
    }

    // MARK: - Helpers

    private func makeStore() -> WearerConversationStore {
        let start = start
        return WearerConversationStore(directory: directory, clock: { start })
    }

    private func makeProvider(
        _ backend: RecordingBackend,
        intentSource: VoiceIntentSource
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            intentSource: intentSource,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            // Bounded rather than the shipped sixty seconds: an unbounded sleep left
            // running in-process stalls whichever test runs next.
            idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) }
        )
    }

    private func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }
}
