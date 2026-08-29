import XCTest
import Foundation
@testable import TapQVoiceBackends
import TapQContracts
@testable import TapQInteractionBaseline

/// The deliberation tool as one stack: a real `VoiceBackendCommandProvider` on top of the
/// real OpenAI Realtime adapter talking to a scripted server, with a fake loop at the far end.
///
/// Everything below has its own tests; these are the ones that would catch a surface that is
/// individually correct and jointly wrong — a declaration that never reaches the wire, an
/// acknowledgment that never becomes a frame, a tool result that leaves the peer parked
/// because the goal took a different path out of the provider.
@MainActor
final class StartTaskRealtimeRoundTripTests: XCTestCase {
    private func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }

    /// Answers with whatever the test scripted and records what it was offered.
    private final class Loop: WearerTaskStarting, @unchecked Sendable {
        private let start: WearerTaskStart
        /// Written inside `startTask` and read by the test after it has awaited the round
        /// trip, so the `await` is the ordering and no lock is needed — which also keeps this
        /// out of the "a lock taken across an await is an error in Swift 6" rule.
        nonisolated(unsafe) private(set) var goals: [String] = []

        init(_ start: WearerTaskStart) { self.start = start }

        func startTask(goal: String) async -> WearerTaskStart {
            goals.append(goal)
            return start
        }
    }

    private struct Stack {
        let server: ScriptedRealtimeServer
        let realtime: OpenAIRealtimeVoiceBackend
        let loop: Loop
        let provider: VoiceBackendCommandProvider
    }

    private func makeStack(_ start: WearerTaskStart) -> Stack {
        let server = ScriptedRealtimeServer()
        let realtime = OpenAIRealtimeVoiceBackend(transport: server, monotonicNow: { 0 })
        let loop = Loop(start)
        return Stack(
            server: server,
            realtime: realtime,
            loop: loop,
            provider: VoiceBackendCommandProvider(
                backend: realtime,
                intentSource: .modelToolCalls,
                sessionPolicy: .conversation(idleClose: 60),
                supportsBargeIn: true,
                startWearerTask: loop,
                // Bounded, so the timer this leaves behind cannot stall the next test in the
                // process. The policy's own idle close is unchanged.
                idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) }
            )
        )
    }

    private func pcm16(_ frames: Int) -> VoiceAudioChunk {
        VoiceAudioChunk(data: Data(repeating: 0x11, count: frames * 2),
                        format: OpenAIRealtimeVoiceBackend.audioFormat, timestamp: 0)
    }

    /// Opens a window, gives the turn something to commit, and commits it — the state a tool
    /// call actually arrives in on this path.
    ///
    /// The audio is not decoration. The scripted server polices the input buffer exactly as
    /// the service does, so a commit over an empty one creates no response at all — and a
    /// fixture in that state would be asserting about a tool call arriving inside a response
    /// that never existed.
    private func openRespondingWindow(_ stack: Stack) async {
        stack.provider.start { _ in }
        await settle()
        stack.realtime.sendAudio(pcm16(2_400))
        stack.provider.endActiveTurn()
        await settle()
    }

    private func toolFrame(_ arguments: String, id: String = "call_1") -> String {
        RealtimeToolFrame.functionCall(callID: id, name: "start_task", arguments: arguments)
    }

    /// The instructions of every `response.create` that carried any, in order.
    ///
    /// By search rather than by index, because the commit that ends the wearer's turn also
    /// creates a response and that one carries none: the scripted sentence is not reliably
    /// the first `response.create` on the wire, only the first one with words in it.
    private func spokenSentences(_ server: ScriptedRealtimeServer) -> [String] {
        server.sent
            .filter { $0["type"] as? String == "response.create" }
            .compactMap { ($0["response"] as? [String: Any])?["instructions"] as? String }
    }

    private func wasSpoken(_ sentence: String, on server: ScriptedRealtimeServer) -> Bool {
        spokenSentences(server).contains { $0.contains(sentence) }
    }

    /// The declaration rides the handshake frame, exactly as the reflex six do, and the
    /// session the model actually sees has seven tools on it.
    func testTheToolReachesTheWireOnTheHandshakeFrame() async {
        let stack = makeStack(.accepted(spoken: "On it."))

        stack.provider.start { _ in }
        await settle()

        let session = stack.server.sessionConfiguration
        let names = (session?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, [
            "approve", "deny", "select_item", "queue_instruction", "query_status", "start_task",
        ])
    }

    /// The whole round trip against the real adapter: a function call inside a response TapQ
    /// asked for, the goal handed to the loop, the peer answered with a
    /// `function_call_output` item, and the acknowledgment leaving as TapQ's own out-of-band
    /// scripted response — one sentence, verbatim, in the words the loop chose.
    func testAGoalRoundTripsAndTheAcknowledgmentLeavesAsScriptedSpeech() async {
        let stack = makeStack(.accepted(spoken: "I'm on it — I'll tell you what the tests say."))
        await openRespondingWindow(stack)
        let callResponse = stack.realtime.activeResponseIdentity

        stack.server.push(toolFrame(#"{"goal":"run the tests and tell me if anything fails"}"#))
        await settle()
        // The response the call arrived in finishes; TapQ's sentence is a separate one.
        stack.server.push(RealtimeFrame.responseDone(id: callResponse ?? ""))
        await settle()

        XCTAssertEqual(stack.loop.goals, ["run the tests and tell me if anything fails"])
        XCTAssertTrue(stack.server.sentTypes.contains("conversation.item.create"),
                      "the peer was left parked on the call: \(stack.server.sentTypes)")

        XCTAssertTrue(
            wasSpoken("I'm on it — I'll tell you what the tests say.", on: stack.server),
            "the acknowledgment never left as speech: \(spokenSentences(stack.server))")
        XCTAssertNotEqual(stack.realtime.activeResponseIdentity, callResponse,
                          "TapQ's sentence must be its own response")
    }

    /// A busy loop is the same round trip with a different sentence. Nothing about it is a
    /// failure: the peer is answered, the wearer is told, and the session carries on.
    func testABusyLoopRoundTripsTheSameWayWithItsOwnSentence() async {
        let busy = "I'm still on the last one — ask me again in a minute."
        let stack = makeStack(.busy(spoken: busy))
        var failures: [String] = []
        stack.provider.onIntentPipelineFailed = { failures.append($0) }
        stack.provider.onScriptedSpeechUndeliverable = { failures.append($0) }
        await openRespondingWindow(stack)
        let callResponse = stack.realtime.activeResponseIdentity

        stack.server.push(toolFrame(#"{"goal":"tell Codex to review that"}"#))
        await settle()
        stack.server.push(RealtimeFrame.responseDone(id: callResponse ?? ""))
        await settle()

        XCTAssertEqual(stack.loop.goals, ["tell Codex to review that"])
        XCTAssertTrue(wasSpoken(busy, on: stack.server),
                      "the busy sentence never left: \(spokenSentences(stack.server))")
        XCTAssertTrue(failures.isEmpty, "a busy loop is not a broken pipe")
    }

    /// Nothing is resolved by a task, right down to the wire: no window command is delivered,
    /// the window stays open, and no `response.cancel` is sent — the response the call arrived
    /// in is left to finish, because nothing about a task means the wearer moved on.
    func testATaskResolvesNothingAndCancelsNothing() async {
        let stack = makeStack(.accepted(spoken: "On it."))
        var delivered: [VoiceCommand] = []
        stack.provider.start { delivered.append($0) }
        await settle()
        stack.realtime.sendAudio(pcm16(2_400))
        stack.provider.endActiveTurn()
        await settle()

        stack.server.push(toolFrame(#"{"goal":"find out why the build broke"}"#))
        await settle()

        XCTAssertEqual(delivered, [])
        XCTAssertTrue(stack.provider.isWindowOpenForTesting)
        XCTAssertFalse(stack.server.sentTypes.contains("response.cancel"))
    }

    /// A blank goal is refused out loud through the same two frames — the peer gets its
    /// output item, the wearer gets a sentence — and the loop is never handed it.
    func testABlankGoalIsRefusedOutLoudOverTheWire() async {
        let stack = makeStack(.accepted(spoken: "should not be reached"))
        await openRespondingWindow(stack)
        let callResponse = stack.realtime.activeResponseIdentity

        stack.server.push(toolFrame(#"{"goal":"  "}"#))
        await settle()
        stack.server.push(RealtimeFrame.responseDone(id: callResponse ?? ""))
        await settle()

        XCTAssertTrue(stack.loop.goals.isEmpty)
        XCTAssertTrue(stack.server.sentTypes.contains("conversation.item.create"))
        XCTAssertTrue(wasSpoken(VoiceIntentTools.emptyGoalNotice, on: stack.server),
                      "the refusal never left: \(spokenSentences(stack.server))")
    }
}
