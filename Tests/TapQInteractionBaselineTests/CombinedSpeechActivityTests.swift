import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class CombinedSpeechActivityTests: XCTestCase {

    // MARK: - Fakes

    @MainActor
    private final class FakeTTSActivity: SpeechActivitySignaling {
        var isSpeaking: Bool
        var onSpeakingChange: (@MainActor (Bool) -> Void)?

        init(speaking: Bool = false) {
            self.isSpeaking = speaking
        }

        func setSpeaking(_ speaking: Bool) {
            guard speaking != isSpeaking else { return }
            isSpeaking = speaking
            onSpeakingChange?(speaking)
        }
    }

    @MainActor
    private final class FakePlayback: VoiceResponseAudioPlaying {
        var isPlaying: Bool
        var onPlayingChange: (@MainActor (Bool) -> Void)?

        private(set) var enqueued: [VoiceAudioChunk] = []
        private(set) var finishStreamCount = 0
        private(set) var stopAndFlushCount = 0

        init(playing: Bool = false) {
            self.isPlaying = playing
        }

        func enqueue(_ chunk: VoiceAudioChunk) {
            enqueued.append(chunk)
            if !isPlaying {
                isPlaying = true
                onPlayingChange?(true)
            }
        }

        func finishStream() {
            finishStreamCount += 1
            // Simulate drain: immediately transition to idle.
            guard isPlaying else { return }
            isPlaying = false
            onPlayingChange?(false)
        }

        func stopAndFlush() {
            stopAndFlushCount += 1
            guard isPlaying else { return }
            isPlaying = false
            onPlayingChange?(false)
        }

        /// Simulate starting/stopping playback externally.
        func setPlaying(_ playing: Bool) {
            guard playing != isPlaying else { return }
            isPlaying = playing
            onPlayingChange?(playing)
        }
    }

    // MARK: - Truth table

    func testBothIdleYieldsCombinedIdle() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)

        XCTAssertFalse(combined.isSpeaking)
    }

    func testTTSBusyAloneYieldsCombinedBusy() async {
        let tts = FakeTTSActivity(speaking: true)
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)

        XCTAssertTrue(combined.isSpeaking)
    }

    func testPlaybackBusyAloneYieldsCombinedBusy() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback(playing: true)
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)

        XCTAssertTrue(combined.isSpeaking)
    }

    func testBothBusyYieldsCombinedBusy() async {
        let tts = FakeTTSActivity(speaking: true)
        let playback = FakePlayback(playing: true)
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)

        XCTAssertTrue(combined.isSpeaking)
    }

    // MARK: - Transition edges

    func testTTSBecomesBusyRaisesCombined() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        var edges: [Bool] = []
        combined.onSpeakingChange = { edges.append($0) }

        tts.setSpeaking(true)

        XCTAssertTrue(combined.isSpeaking)
        XCTAssertEqual(edges, [true])
    }

    func testPlaybackBecomesBusyRaisesCombined() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        var edges: [Bool] = []
        combined.onSpeakingChange = { edges.append($0) }

        playback.setPlaying(true)

        XCTAssertTrue(combined.isSpeaking)
        XCTAssertEqual(edges, [true])
    }

    func testTTSDrainsWhilePlaybackBusyStaysCombinedBusy() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        var edges: [Bool] = []

        tts.setSpeaking(true)
        playback.setPlaying(true)
        combined.onSpeakingChange = { edges.append($0) }

        // TTS finishes but playback is still going
        tts.setSpeaking(false)

        XCTAssertTrue(combined.isSpeaking, "playback alone keeps combined busy")
        XCTAssertEqual(edges, [], "no edge: combined was busy and stays busy")
    }

    func testPlaybackDrainsWhileTTSBusyStaysCombinedBusy() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        var edges: [Bool] = []

        tts.setSpeaking(true)
        playback.setPlaying(true)
        combined.onSpeakingChange = { edges.append($0) }

        // Playback finishes but TTS is still going
        playback.setPlaying(false)

        XCTAssertTrue(combined.isSpeaking, "TTS alone keeps combined busy")
        XCTAssertEqual(edges, [], "no edge: combined was busy and stays busy")
    }

    func testBothDrainYieldsCombinedIdle() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        var edges: [Bool] = []

        tts.setSpeaking(true)
        playback.setPlaying(true)
        combined.onSpeakingChange = { edges.append($0) }

        tts.setSpeaking(false)
        playback.setPlaying(false)

        XCTAssertFalse(combined.isSpeaking)
        XCTAssertEqual(edges, [false], "exactly one falling edge when the last source drains")
    }

    func testExactlyOneTransitionPerOuterChange() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        var edges: [Bool] = []
        combined.onSpeakingChange = { edges.append($0) }

        // Full cycle: idle -> tts busy -> both busy -> tts idle -> playback idle
        tts.setSpeaking(true)       // idle -> busy
        playback.setPlaying(true)   // busy -> busy (no edge)
        tts.setSpeaking(false)      // busy -> busy (no edge)
        playback.setPlaying(false)  // busy -> idle

        XCTAssertEqual(edges, [true, false],
                       "exactly two transitions for the full busy/idle cycle")
    }

    func testNoDuplicateEdgesOnRedundantInnerTransitions() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        var edges: [Bool] = []
        combined.onSpeakingChange = { edges.append($0) }

        // TTS goes busy, idle, busy, idle — playback stays idle throughout.
        tts.setSpeaking(true)
        tts.setSpeaking(false)
        tts.setSpeaking(true)
        tts.setSpeaking(false)

        XCTAssertEqual(edges, [true, false, true, false],
                       "each inner edge that changes combined fires exactly one outer edge")
    }

    // MARK: - Composition with SpeechGatedVoice

    @MainActor
    private final class FakeVoice: VoiceCommandProviding {
        var onCommand: (@MainActor (VoiceCommand) -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0
        func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
            starts += 1
            self.onCommand = onCommand
        }
        func stop() { stops += 1 }
        func fire(_ command: VoiceCommand) { onCommand?(command) }
    }

    func testSpeechGatedVoiceHoldsMicClosedWhilePlaybackBusy() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        let inner = FakeVoice()
        let gated = SpeechGatedVoice(wrapping: inner, activity: combined)
        var received: [VoiceCommand] = []

        gated.start { received.append($0) }
        XCTAssertEqual(inner.starts, 1, "mic opens when idle")

        // Backend audio starts playing
        playback.setPlaying(true)
        XCTAssertEqual(inner.stops, 1, "mic closes when playback starts")

        // Backend audio drains
        playback.setPlaying(false)
        XCTAssertEqual(inner.starts, 2, "mic reopens when playback drains")
    }

    func testSpeechGatedVoiceHoldsMicClosedWhileTTSAndPlaybackOverlap() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        let inner = FakeVoice()
        let gated = SpeechGatedVoice(wrapping: inner, activity: combined)

        // Both busy before the window opens
        tts.setSpeaking(true)
        playback.setPlaying(true)
        gated.start { _ in }
        XCTAssertEqual(inner.starts, 0, "mic stays closed while both are busy")

        // TTS drains first, playback still going
        tts.setSpeaking(false)
        XCTAssertEqual(inner.starts, 0, "mic stays closed: playback still busy")

        // Playback drains
        playback.setPlaying(false)
        XCTAssertEqual(inner.starts, 1, "mic opens only when everything is idle")
    }

    func testSpeechGatedVoiceReopensAfterPlaybackDrain() async {
        let tts = FakeTTSActivity()
        let playback = FakePlayback()
        let combined = CombinedSpeechActivity(tts: tts, playback: playback)
        let inner = FakeVoice()
        let gated = SpeechGatedVoice(wrapping: inner, activity: combined)
        var received: [VoiceCommand] = []

        gated.start { received.append($0) }
        XCTAssertEqual(inner.starts, 1)

        // Playback busy then drain
        playback.setPlaying(true)
        playback.setPlaying(false)
        XCTAssertEqual(inner.starts, 2)

        // Voice command arrives after reopen
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }
}
