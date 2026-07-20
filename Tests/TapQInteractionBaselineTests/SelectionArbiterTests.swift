import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class SelectionArbiterTests: XCTestCase {
    @MainActor final class FakeVoice: VoiceCommandProviding {
        var onCommand: (@MainActor (VoiceCommand) -> Void)?
        var stopped = false
        func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) { self.onCommand = onCommand }
        func stop() { stopped = true }
        func fire(_ c: VoiceCommand) { onCommand?(c) }
    }

    @MainActor final class FakeTilts: TiltCommandProviding {
        var onTilt: (@MainActor (TiltCommand) -> Void)?
        var stopped = false
        func start(onTilt: @escaping @MainActor (TiltCommand) -> Void) { self.onTilt = onTilt }
        func stop() { stopped = true }
        func fire(_ t: TiltCommand) { onTilt?(t) }
    }

    @MainActor final class FakeSwipes: VolumeSwipeProviding {
        var onSwipe: (@MainActor (VolumeSwipeCommand) -> Void)?
        var stopped = false
        func start(onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void) { self.onSwipe = onSwipe }
        func stop() { stopped = true }
        func fire(_ s: VolumeSwipeCommand) { onSwipe?(s) }
    }

    @MainActor final class FakeTaps: TapCommandProviding {
        var onTap: (@MainActor (TapCommand) -> Void)?
        var stopped = false
        func start(onTap: @escaping @MainActor (TapCommand) -> Void) { self.onTap = onTap }
        func stop() { stopped = true }
        func fire() { onTap?(.tap) }
    }

    @MainActor final class FakeGestures: HeadGestureProviding {
        var onGesture: (@MainActor (HeadGesture) -> Void)?
        var stopped = false
        func start(onGesture: @escaping @MainActor (HeadGesture) -> Void) {
            self.onGesture = onGesture
        }
        func stop() { stopped = true }
        func fire(_ gesture: HeadGesture) { onGesture?(gesture) }
    }

    private func tick() async { try? await Task.sleep(nanoseconds: 30_000_000) }

    func testVoiceNextResolvesNext() async {
        let voice = FakeVoice()
        let arbiter = SelectionArbiter(voice: voice, tilts: nil, swipes: nil, taps: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        voice.fire(.next)
        let result = await task.value
        XCTAssertEqual(result, .next)
    }

    func testTiltRightResolvesNext() async {
        let tilts = FakeTilts()
        let arbiter = SelectionArbiter(voice: nil, tilts: tilts, swipes: nil, taps: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        tilts.fire(.tiltRight)
        let result = await task.value
        XCTAssertEqual(result, .next)
    }

    func testTiltLeftResolvesPrevious() async {
        let tilts = FakeTilts()
        let arbiter = SelectionArbiter(voice: nil, tilts: tilts, swipes: nil, taps: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        tilts.fire(.tiltLeft)
        let result = await task.value
        XCTAssertEqual(result, .previous)
    }

    func testSwipeDownResolvesNext() async {
        let swipes = FakeSwipes()
        let arbiter = SelectionArbiter(voice: nil, tilts: nil, swipes: swipes, taps: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        swipes.fire(.swipeDown)
        let result = await task.value
        XCTAssertEqual(result, .next)
    }

    func testTapResolvesSelect() async {
        let taps = FakeTaps()
        let arbiter = SelectionArbiter(voice: nil, tilts: nil, swipes: nil, taps: taps)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        taps.fire()
        let result = await task.value
        XCTAssertEqual(result, .allow)
    }

    func testNodResolvesSelect() async {
        let gestures = FakeGestures()
        let arbiter = SelectionArbiter(
            voice: nil, tilts: nil, swipes: nil, taps: nil, gestures: gestures)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        gestures.fire(.nod)
        let result = await task.value
        XCTAssertEqual(result, .select)
        XCTAssertTrue(gestures.stopped)
    }

    func testShakeDefersSelection() async {
        let gestures = FakeGestures()
        let arbiter = SelectionArbiter(
            voice: nil, tilts: nil, swipes: nil, taps: nil, gestures: gestures)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        gestures.fire(.shake)
        let result = await task.value
        XCTAssertEqual(result, .deny)
    }

    func testVoiceSelectResolvesSelect() async {
        let voice = FakeVoice()
        let arbiter = SelectionArbiter(voice: voice, tilts: nil, swipes: nil, taps: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        voice.fire(.select)
        let result = await task.value
        XCTAssertEqual(result, .select)
    }

    func testVoiceNumberResolvesSelectByNumber() async {
        let voice = FakeVoice()
        let arbiter = SelectionArbiter(voice: voice, tilts: nil, swipes: nil, taps: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        voice.fire(.number(3))
        let result = await task.value
        XCTAssertEqual(result, .selectByNumber(3))
    }

    func testTimeoutResolvesNil() async {
        let voice = FakeVoice()
        let arbiter = SelectionArbiter(voice: voice, tilts: nil, swipes: nil, taps: nil)
        let result = await arbiter.listen(timeout: 0.05)
        XCTAssertNil(result)
        XCTAssertTrue(voice.stopped)
    }

    func testFirstInputWins() async {
        let voice = FakeVoice()
        let tilts = FakeTilts()
        let arbiter = SelectionArbiter(voice: voice, tilts: tilts, swipes: nil, taps: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        tilts.fire(.tiltRight)
        voice.fire(.next)  // ignored — already resolved
        let result = await task.value
        XCTAssertEqual(result, .next)
    }

    func testGestureWinsAndStopsEveryChannel() async {
        let voice = FakeVoice()
        let swipes = FakeSwipes()
        let taps = FakeTaps()
        let gestures = FakeGestures()
        let arbiter = SelectionArbiter(
            voice: voice, tilts: nil, swipes: swipes, taps: taps,
            gestures: gestures)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        gestures.fire(.nod)
        swipes.fire(.swipeDown)
        let result = await task.value
        XCTAssertEqual(result, .select)
        XCTAssertTrue(voice.stopped)
        XCTAssertTrue(swipes.stopped)
        XCTAssertTrue(taps.stopped)
        XCTAssertTrue(gestures.stopped)
    }

    func testOverlappingListenResolvesStaleWindowAsTimeout() async {
        let voice = FakeVoice()
        let arbiter = SelectionArbiter(voice: voice, tilts: nil, swipes: nil, taps: nil)

        let first = Task { await arbiter.listen(timeout: 5) }
        await tick()
        let second = Task { await arbiter.listen(timeout: 5) }
        await tick()

        let firstResult = await first.value
        XCTAssertNil(firstResult)

        voice.fire(.no)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, .deny)
    }

    func testCancelResolvesPendingListenAsNil() async {
        let voice = FakeVoice()
        let arbiter = SelectionArbiter(voice: voice, tilts: nil, swipes: nil, taps: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        arbiter.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(voice.stopped)
    }

    @MainActor
    final class FakeActivity: SpeechActivitySignaling {
        private(set) var isSpeaking = false
        var onSpeakingChange: (@MainActor (Bool) -> Void)?
        func setSpeaking(_ speaking: Bool) {
            guard speaking != isSpeaking else { return }
            isSpeaking = speaking
            onSpeakingChange?(speaking)
        }
    }

    func testVoiceClosedDuringTTSButTiltIsLive() async {
        let voice = FakeVoice()
        let tilts = FakeTilts()
        let activity = FakeActivity()
        activity.setSpeaking(true)
        let arbiter = SelectionArbiter(
            voice: SpeechGatedVoice(wrapping: voice, activity: activity),
            tilts: tilts, swipes: nil, taps: nil)

        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        XCTAssertNotNil(tilts.onTilt, "tilt channel opens immediately during TTS")
        XCTAssertNil(voice.onCommand)

        tilts.fire(.tiltRight) // navigate while the option is still being spoken
        let result = await task.value
        XCTAssertEqual(result, .next)

        activity.setSpeaking(false)
        await tick()
        XCTAssertNil(voice.onCommand, "mic never opens for a resolved window")
    }
}
