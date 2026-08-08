import XCTest
@testable import TapQVoiceBackends
import TapQContracts
@testable import TapQInteractionBaseline

/// The whole point of the milestone's voice work, exercised as one stack: a command
/// provider on top of a fail-through wrapper on top of the real OpenAI Realtime adapter
/// talking to a scripted server, with the Apple stack underneath as the fallback.
///
/// Every layer below has its own tests; these are the ones that would catch a composition
/// that is individually correct and jointly useless — a socket that dies mid-window and
/// takes the wearer's approval with it.
///
/// The fallback is a `ScriptedVoiceBackend` rather than `AppleVoiceBackend` deliberately:
/// this target is portable, and what matters here is that the *composition* recovers, not
/// which recognizer answers.
@MainActor
final class VoiceBackendFailThroughWindowTests: XCTestCase {
    private func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }

    /// Stands in for `VoiceCommandMatcher.match`, which lives in a target this one does not
    /// depend on. The grammar is not what is under test; cumulative-transcript matching is.
    private nonisolated func match(_ transcript: String) -> VoiceCommand? {
        let text = transcript.lowercased()
        if text.contains("yes") { return .yes }
        if text.contains("no") { return .no }
        return nil
    }

    private struct Stack {
        let server: ScriptedRealtimeServer
        let realtime: OpenAIRealtimeVoiceBackend
        let apple: ScriptedVoiceBackend
        let failThrough: FailThroughVoiceBackend
        let provider: VoiceBackendCommandProvider
    }

    private func makeStack() -> Stack {
        let server = ScriptedRealtimeServer()
        let realtime = OpenAIRealtimeVoiceBackend(transport: server, monotonicNow: { 0 })
        let apple = ScriptedVoiceBackend(name: "apple")
        let failThrough = FailThroughVoiceBackend(primary: realtime, fallback: apple)
        return Stack(
            server: server,
            realtime: realtime,
            apple: apple,
            failThrough: failThrough,
            provider: VoiceBackendCommandProvider(backend: failThrough,
                                                  match: { self.match($0) })
        )
    }

    func testATransportDeathMidWindowStillResolvesTheWindowOnTheFallback() async {
        let stack = makeStack()
        var delivered: [VoiceCommand] = []

        stack.provider.start { delivered.append($0) }
        await settle()
        XCTAssertEqual(stack.server.sentTypes.first, "session.update",
                       "the realtime session must be the one that opened")
        XCTAssertEqual(stack.apple.calls, [], "the fallback stays inert while the cloud works")

        // The wearer is mid-sentence and the socket dies.
        stack.server.disconnect()
        await settle()

        XCTAssertEqual(stack.apple.calls, [.open, .beginUserTurn],
                       "the window moves to the on-device stack with its turn intact")
        XCTAssertTrue(delivered.isEmpty, "nothing is delivered by the failure itself")

        // The wearer answers into the recovered window.
        stack.apple.emit(.transcriptPartial("yes"))

        XCTAssertEqual(delivered, [.yes],
                       "the approval still resolves by voice; the caller never learns why")
        XCTAssertEqual(stack.apple.calls,
                       [.open, .beginUserTurn, .endUserTurn, .close],
                       "the recovered window tears down exactly like a healthy one")
        XCTAssertFalse(stack.provider.isWindowOpenForTesting)
    }

    /// The failure has to be invisible above the seam: no window is torn down, and no
    /// second `start` is needed to keep listening.
    func testTheCommandProviderNeverSeesTheFailure() async {
        let stack = makeStack()
        stack.provider.start { _ in }
        await settle()

        stack.server.disconnect()
        await settle()

        XCTAssertTrue(stack.provider.isWindowOpenForTesting,
                      "a dead primary must not resolve or abandon the wearer's window")
    }

    func testAHealthyRealtimeWindowResolvesWithoutTouchingTheFallback() async {
        let stack = makeStack()
        var delivered: [VoiceCommand] = []

        stack.provider.start { delivered.append($0) }
        await settle()
        stack.server.push(RealtimeFrame.transcriptDelta("yes"))
        await settle()

        XCTAssertEqual(delivered, [.yes])
        XCTAssertEqual(stack.apple.calls, [],
                       "a working cloud window must cost the on-device stack nothing")
        await settle()
        // Nothing but the manual-turn configuration ever left: the match resolved the
        // window, so the session was torn down before anything could ask for a response.
        // The invariant that matters is the negative one — no `response.create` was sent,
        // and the peer had no way to produce one on its own.
        XCTAssertEqual(stack.server.sentTypes, ["session.update"])
        XCTAssertEqual(stack.server.closeCount, 1,
                       "a resolved window closes the realtime session")
    }

    /// Both pipes gone is the one case that surfaces: the window then resolves by gesture,
    /// tap, or timeout, which is exactly what a torn-down provider leaves it free to do.
    func testWhenTheFallbackAlsoFailsTheWindowClosesQuietly() async {
        let stack = makeStack()
        stack.apple.openFailure = .authorization("speech recognition is unavailable")
        var delivered: [VoiceCommand] = []

        stack.provider.start { delivered.append($0) }
        await settle()
        stack.server.disconnect()
        await settle()

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertFalse(stack.provider.isWindowOpenForTesting,
                       "with nothing left underneath, the voice window gives up rather than hanging")
    }
}
