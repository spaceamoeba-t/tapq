import XCTest
@testable import TapQVoiceBackends
import TapQContracts
@testable import TapQInteractionBaseline

/// The failure policy exercised as one stack: a real `VoiceBackendCommandProvider` on top of
/// the break latch on top of the real OpenAI Realtime adapter talking to a scripted server.
///
/// Every layer below has its own tests; these are the ones that would catch a policy that is
/// individually correct and jointly wrong — a socket that dies mid-window and leaves the
/// provider holding a window it thinks is still listening, or a later window that quietly
/// reconnects the pipe the run already declared dead.
///
/// The stack has exactly one backend in it. That is the assertion the whole file is built
/// around: after the break there is nowhere for a window to go but gestures, taps, and the
/// timeout, and nothing in this composition can take it anywhere else.
@MainActor
final class VoiceBackendBreakWindowTests: XCTestCase {
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

    @MainActor
    private final class HostSide {
        private(set) var spoken: [String] = []
        private(set) var releases = 0

        func install(on latch: VoiceBrokenState) {
            latch.speakNotice = { [weak self] in self?.spoken.append($0) }
            latch.releaseHolds = { [weak self] in self?.releases += 1 }
        }
    }

    private struct Stack {
        let server: ScriptedRealtimeServer
        let realtime: OpenAIRealtimeVoiceBackend
        let broken: VoiceBrokenState
        let host: HostSide
        let provider: VoiceBackendCommandProvider
    }

    private func makeStack(sessionPolicy: SessionPolicy = .perWindow) -> Stack {
        let server = ScriptedRealtimeServer()
        let realtime = OpenAIRealtimeVoiceBackend(transport: server, monotonicNow: { 0 })
        let broken = VoiceBrokenState(inner: realtime, provider: .openaiRealtime)
        let host = HostSide()
        host.install(on: broken)
        return Stack(
            server: server,
            realtime: realtime,
            broken: broken,
            host: host,
            provider: VoiceBackendCommandProvider(
                backend: broken,
                match: { self.match($0) },
                sessionPolicy: sessionPolicy,
                // Long enough that no test here reaches an idle close, short enough that the
                // sleep it leaves behind cannot stall the next test in the process. The
                // policy's own `idleClose` stays whatever the test asked for; only how long
                // the timer actually waits is bounded.
                idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) }
            )
        )
    }

    // MARK: - A healthy window is untouched

    func testAHealthyWindowResolvesAndTheLatchNeverFires() async {
        let stack = makeStack()
        var delivered: [VoiceCommand] = []

        stack.provider.start { delivered.append($0) }
        await settle()
        stack.server.push(RealtimeFrame.transcriptDelta("yes"))
        await settle()

        XCTAssertEqual(delivered, [.yes])
        XCTAssertFalse(stack.broken.isBroken)
        XCTAssertTrue(stack.host.spoken.isEmpty)
        // Nothing but the manual-turn configuration ever left: the match resolved the
        // window before anything could ask for a response.
        XCTAssertEqual(stack.server.sentTypes, ["session.update"])
        XCTAssertEqual(stack.server.closeCount, 1,
                       "a resolved window closes the realtime session")
    }

    // MARK: - The socket dies mid-window

    /// The wearer is mid-sentence and the socket dies. There is no second pipe to carry the
    /// turn, so the window gives up its voice channel — and says so — rather than hanging on
    /// one that is gone.
    func testATransportDeathMidWindowBreaksTheRunAndReleasesTheWindow() async {
        let stack = makeStack()
        var delivered: [VoiceCommand] = []

        stack.provider.start { delivered.append($0) }
        await settle()
        XCTAssertEqual(stack.server.sentTypes.first, "session.update",
                       "the realtime session must be the one that opened")

        stack.server.disconnect()
        await settle()

        XCTAssertTrue(stack.broken.isBroken)
        XCTAssertTrue(delivered.isEmpty, "nothing is delivered by the failure itself")
        XCTAssertFalse(stack.provider.isWindowOpenForTesting,
                       "a window with no voice channel resolves by gesture, tap, or timeout")
        XCTAssertEqual(stack.host.spoken, [VoiceBrokenState.spokenNotice],
                       "the wearer is told once, in TapQ's own voice")
        XCTAssertEqual(stack.host.releases, 1,
                       "a held boundary is let go rather than waiting out its budget")
    }

    /// The same death, inside a conversation-mode session — the shape the runtime actually
    /// composes. The session is not reopened at the next window, and the wearer is not told
    /// a second time.
    func testAfterTheBreakLaterWindowsOpenWithoutAMicrophone() async {
        let stack = makeStack(sessionPolicy: .conversation(idleClose: 3_600))

        stack.provider.start { _ in }
        await settle()
        stack.server.disconnect()
        await settle()
        let connectsAtBreak = stack.server.connectCount

        for _ in 0..<3 {
            stack.provider.start { _ in }
            await settle()
            stack.provider.stop()
            await settle()
        }

        XCTAssertEqual(stack.server.connectCount, connectsAtBreak,
                       "a dead pipe is never re-probed, however many windows follow")
        XCTAssertFalse(stack.provider.isWindowOpenForTesting)
        XCTAssertEqual(stack.host.spoken.count, 1,
                       "one break, one notice: \(stack.host.spoken)")
        XCTAssertEqual(stack.host.releases, 1)
    }

    /// A transcript the peer manages to deliver after the break reaches no grammar. There is
    /// no session left for it to belong to, and a window resolved by a dead pipe's leftovers
    /// would be the exact thing "no voice channel" is supposed to rule out.
    func testNothingResolvesAWindowAfterTheBreak() async {
        let stack = makeStack(sessionPolicy: .conversation(idleClose: 3_600))
        var delivered: [VoiceCommand] = []

        stack.provider.start { delivered.append($0) }
        await settle()
        stack.server.disconnect()
        await settle()

        stack.provider.start { delivered.append($0) }
        await settle()
        stack.server.push(RealtimeFrame.transcriptDelta("yes"))
        await settle()

        XCTAssertTrue(delivered.isEmpty,
                      "a window with no microphone answered anyway: \(delivered)")
    }

    // MARK: - An open that fails

    /// The first window of a run whose credentials the peer rejects. There is nothing to
    /// fall back to, so the run's voice ends at the handshake rather than at the first
    /// dropped socket.
    func testAnOpenThatFailsBreaksTheRunFromTheFirstWindow() async {
        let stack = makeStack()
        stack.server.connectFailure = .connectFailed("no route to host")

        stack.provider.start { _ in }
        await settle()

        XCTAssertTrue(stack.broken.isBroken)
        XCTAssertFalse(stack.provider.isWindowOpenForTesting)
        XCTAssertEqual(stack.host.spoken, [VoiceBrokenState.spokenNotice])

        stack.provider.start { _ in }
        await settle()
        XCTAssertEqual(stack.server.connectCount, 1,
                       "the failed handshake is not retried at the next window")
    }

    // MARK: - Scripted speech through the whole stack

    /// Every sentence TapQ says goes out as an out-of-band verbatim response on the pipe the
    /// operator named, and the local synthesizer is never asked for any of them.
    ///
    /// `host.spoken` is the local voice in this stack — it is wired to the latch's
    /// `speakNotice` and to nothing else. Its emptiness here is the whole claim: a healthy
    /// run has one voice.
    func testScriptedSentencesGoOutOnTheBackendAndNotTheLocalVoice() async {
        let stack = makeStack(sessionPolicy: .conversation(idleClose: 3_600))

        stack.provider.speakScripted("Codex finished.")
        await settle()

        XCTAssertEqual(stack.server.sentTypes, ["session.update", "response.create"])
        let response = stack.server.responseObject(at: 0)
        XCTAssertEqual(response?["conversation"] as? String, "none")
        XCTAssertTrue((response?["instructions"] as? String)?
            .contains("Codex finished.") ?? false)
        XCTAssertTrue(stack.host.spoken.isEmpty,
                      "a healthy backend leaves the local voice silent: \(stack.host.spoken)")
        XCTAssertFalse(stack.broken.isBroken)
    }

    /// The failure direction of the same seam, which is the half that must never be a
    /// fallback. A sentence the specified backend cannot carry ends hands-free voice for the
    /// run — loudly, once — rather than quietly arriving in a second voice.
    ///
    /// The local notice that follows is the sole exception to the isolation rule, and it is
    /// spoken by the latch precisely because by then there is no pipe left to speak through.
    func testAnUndeliverableSentenceBreaksTheRunRatherThanFallingBackToTheLocalVoice() async {
        let stack = makeStack(sessionPolicy: .conversation(idleClose: 3_600))
        stack.server.connectFailure = .connectFailed("no route to host")
        var reported: [String] = []
        stack.provider.onScriptedSpeechUndeliverable = { [broken = stack.broken] reason in
            reported.append(reason)
            broken.noteBackendFailed(reason: "scripted speech undeliverable: \(reason)")
        }

        stack.provider.speakScripted("Claude Code wants to run the tests.")
        await settle()

        XCTAssertEqual(reported, ["session_open_failed"])
        XCTAssertTrue(stack.broken.isBroken)
        XCTAssertEqual(stack.host.spoken, [VoiceBrokenState.spokenNotice],
                       "the only sentence the local voice may say is that voice is off")
        XCTAssertEqual(stack.host.releases, 1)
    }
}
