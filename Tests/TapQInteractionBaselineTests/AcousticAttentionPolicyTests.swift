import Foundation
import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The decision half of `--attention acoustic`, which is all of it that holds a rule.
///
/// Every test here drives the policy with a fake sample stream on an arbitrary timeline, so
/// what is being pinned is the rule and not a room: at what level, for how long, how often,
/// and never while TapQ is the one making the noise.
@MainActor
final class AcousticAttentionPolicyTests: XCTestCase {
    // MARK: - Doubles

    /// TapQ's own voice, as the composition reports it: a read, never a subscription.
    ///
    /// It occupies the same injected timeline the samples do — `speak(from:to:)` says when
    /// the audio started and stopped, and `isAudible(at:)` is what the policy's closure ends
    /// up asking. An instantaneous "speaking now" flag could not express the case this rung
    /// most needs to survive, which is the beat *after* TapQ stops and the room is still
    /// ringing.
    @MainActor
    private final class SelfVoiceDouble {
        private var startedAt: TimeInterval?
        private var stoppedAt: TimeInterval?
        /// The instant the policy is currently asking about, set by the harness before each
        /// sample. The closure the policy holds takes no arguments, so this is how a
        /// wall-clock-free double answers a question about a point in time.
        var askingAbout: TimeInterval = 0

        func speak(from start: TimeInterval, to end: TimeInterval) {
            startedAt = start
            stoppedAt = end
        }

        func beginSpeaking(at start: TimeInterval) {
            startedAt = start
            stoppedAt = nil
        }

        func isAudible() -> Bool {
            guard let startedAt, askingAbout >= startedAt else { return false }
            guard let stoppedAt else { return true }
            return askingAbout <= stoppedAt
        }
    }

    /// A policy plus the sample pump that feeds it, so a test can say "quiet for a second,
    /// then speech for a second" instead of writing two loops every time.
    @MainActor
    private final class Harness {
        let policy: AcousticAttentionPolicy
        let voice: SelfVoiceDouble
        private(set) var onsets: [TimeInterval] = []
        /// The capture block period. 20 ms is about what a 1024-frame tap at 48 kHz
        /// delivers, which is the block size the production source installs.
        let blockPeriod: TimeInterval = 0.02
        /// An arbitrary point on the injected timeline. Non-zero so that "before the run
        /// started" is expressible and a stray zero would show up as an obvious answer.
        private(set) var now: TimeInterval = 100

        init(configuration: AcousticAttentionConfiguration = AcousticAttentionConfiguration()) {
            let voice = SelfVoiceDouble()
            self.voice = voice
            self.policy = AcousticAttentionPolicy(
                configuration: configuration,
                isSelfAudible: { voice.isAudible() }
            )
            policy.onOnset = { [weak self] in
                guard let self else { return }
                self.onsets.append(self.now)
            }
        }

        /// Starts listening and advances past the resume settling, which every test that is
        /// not *about* the settling wants out of its way. The settling is deliberate — see
        /// `testAResumeSettlesBeforeItWillFire` — and skipping it here is what keeps the
        /// other tests about the rule they are named for.
        func beginListening() {
            policy.setSuspended(false, at: now)
            skip(seconds: policy.configuration.selfAudioHangover + blockPeriod)
        }

        /// Feeds `seconds` of blocks at `level`, advancing the injected clock by one block
        /// period each time. Returns the instant after the last block.
        @discardableResult
        func feed(level: Double, seconds: TimeInterval) -> TimeInterval {
            let blocks = Int((seconds / blockPeriod).rounded())
            for _ in 0..<blocks {
                voice.askingAbout = now
                policy.noteLevel(level, at: now)
                now += blockPeriod
            }
            return now
        }

        /// Advances the clock without delivering any samples — a suspension, or simply a
        /// stretch of the run this test does not care about.
        func skip(seconds: TimeInterval) {
            now += seconds
        }
    }

    private let speech = 0.08
    private let quiet = 0.001

    // MARK: - The onset itself

    func testSustainedSpeechLevelFiresOneOnset() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: quiet, seconds: 1.0)
        harness.feed(level: speech, seconds: 1.0)

        XCTAssertEqual(harness.onsets.count, 1)
        XCTAssertEqual(harness.policy.onsetCount, 1)
    }

    /// The onset arrives once the level has held for the minimum duration, not the moment it
    /// crosses. A wearer waiting on "Yes?" is waiting exactly that long and no longer.
    func testTheOnsetFiresAtTheMinimumDurationAndNotBefore() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: quiet, seconds: 1.0)
        let speechStarted = harness.now
        harness.feed(level: speech, seconds: 1.0)

        guard let onset = harness.onsets.first else {
            return XCTFail("Expected an onset.")
        }
        let held = onset - speechStarted
        let minimum = AcousticAttentionConfiguration.defaultMinimumDuration
        XCTAssertGreaterThanOrEqual(held, minimum)
        XCTAssertLessThan(held, minimum + 3 * harness.blockPeriod,
                          "the onset must land on the deadline, not well past it")
    }

    /// The whole reason for the debounce: a desk is full of loud things that are over before
    /// a syllable would be.
    func testABlipShorterThanTheDebounceFiresNothing() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: quiet, seconds: 0.5)
        harness.feed(level: speech, seconds: 0.1)
        harness.feed(level: quiet, seconds: 1.0)

        XCTAssertEqual(harness.onsets.count, 0)
    }

    /// Ten separate blips do not add up to one sentence. The stretch has to be continuous —
    /// which is what keeps a keyboard from opening a window.
    func testRepeatedBlipsDoNotAccumulateIntoAnOnset() async {
        let harness = Harness()
        harness.beginListening()
        for _ in 0..<10 {
            harness.feed(level: speech, seconds: 0.1)
            harness.feed(level: quiet, seconds: 0.3)
        }

        XCTAssertEqual(harness.onsets.count, 0)
    }

    func testALevelBelowTheThresholdNeverFires() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: AcousticAttentionConfiguration.defaultOnsetLevel - 0.001,
                     seconds: 3.0)

        XCTAssertEqual(harness.onsets.count, 0)
    }

    /// The threshold is inclusive: a block exactly at it counts, so an operator who sets the
    /// environment key to the level they measured gets the behavior they measured.
    func testALevelExactlyAtTheThresholdCounts() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: AcousticAttentionConfiguration.defaultOnsetLevel, seconds: 1.0)

        XCTAssertEqual(harness.onsets.count, 1)
    }

    // MARK: - Gaps inside speech

    /// Speech has silence in it. A gap shorter than the tolerance must not restart the clock,
    /// or a wearer would have to hold a vowel to be heard.
    func testAGapShorterThanTheToleranceDoesNotBreakTheStretch() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: speech, seconds: 0.1)
        harness.feed(level: quiet, seconds: 0.06)
        harness.feed(level: speech, seconds: 0.14)

        XCTAssertEqual(harness.onsets.count, 1,
                       "0.1s + 0.14s of sound across a 60ms gap is one 200ms stretch")
    }

    func testAGapLongerThanTheToleranceEndsTheStretch() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: speech, seconds: 0.1)
        harness.feed(level: quiet, seconds: 0.3)
        harness.feed(level: speech, seconds: 0.14)

        XCTAssertEqual(harness.onsets.count, 0,
                       "two short stretches either side of a real pause are two noises")
    }

    // MARK: - One utterance, one onset

    /// A sentence keeps going after the window opens. The second syllable is not a second
    /// request for attention.
    func testAContinuousStretchIsDecidedExactlyOnce() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: speech, seconds: 6.0)

        XCTAssertEqual(harness.onsets.count, 1)
    }

    /// A second sentence inside the cooldown is the same wearer still talking into a window
    /// that is already open.
    func testASecondUtteranceInsideTheCooldownIsRefused() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: speech, seconds: 0.5)
        harness.feed(level: quiet, seconds: 1.0)
        harness.feed(level: speech, seconds: 0.5)

        XCTAssertEqual(harness.onsets.count, 1)
    }

    /// And once the cooldown has run out, the wearer can ask for attention again — otherwise
    /// this is a feature that works once.
    func testAnUtteranceAfterTheCooldownFiresAgain() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: speech, seconds: 0.5)
        harness.feed(level: quiet, seconds: 0.5)
        harness.skip(seconds: AcousticAttentionConfiguration.defaultCooldown)
        harness.feed(level: speech, seconds: 0.5)

        XCTAssertEqual(harness.onsets.count, 2)
    }

    /// The cooldown is measured from the onset, and time passes while a window is open — so a
    /// wearer whose eight seconds have just closed is not made to wait a second cooldown.
    func testTheCooldownIsMeasuredFromTheOnsetAndNotFromTheResume() async {
        let harness = Harness()
        harness.beginListening()
        harness.feed(level: speech, seconds: 0.5)

        // The composition suspends for the window, which outlasts the cooldown.
        harness.policy.setSuspended(true, at: harness.now)
        harness.skip(seconds: AcousticAttentionConfiguration.defaultCooldown + 1)
        harness.policy.setSuspended(false, at: harness.now)

        // Past the resume settling, then a fresh sentence.
        harness.feed(level: quiet, seconds: 1.0)
        harness.feed(level: speech, seconds: 0.5)

        XCTAssertEqual(harness.onsets.count, 2)
    }

    // MARK: - Half-duplex

    /// The rule with no threshold behind it: on a machine with no earbuds, TapQ's own answer
    /// is the loudest thing this microphone hears all day.
    func testSpeechLevelWhileTapQIsSpeakingFiresNothing() async {
        let harness = Harness()
        harness.beginListening()
        harness.voice.beginSpeaking(at: harness.now)
        harness.feed(level: speech, seconds: 3.0)

        XCTAssertEqual(harness.onsets.count, 0)
    }

    /// The beat after TapQ stops is still TapQ: output latency, the room's ring, and the lag
    /// in the signal that reports either. An instantaneous busy flag cannot express this case,
    /// which is why the double carries a span.
    func testTheHangoverAfterTapQStopsIsStillSuppressed() async {
        let harness = Harness()
        harness.beginListening()
        let stops = harness.now + 1.0
        harness.voice.speak(from: harness.now, to: stops)

        // A full second of TapQ, then its tail — well inside the hangover — at speech level.
        harness.feed(level: speech, seconds: 1.0)
        harness.feed(level: speech, seconds: VoiceSelfAudioEcho.defaultHysteresis - 0.1)

        XCTAssertEqual(harness.onsets.count, 0)
    }

    /// And the hangover ends. A wearer answering promptly is still heard, or half-duplex
    /// would have become a microphone that ignores them.
    func testTheWearerIsHeardOnceTheHangoverHasRunOut() async {
        let harness = Harness()
        harness.beginListening()
        harness.voice.speak(from: harness.now, to: harness.now + 1.0)
        harness.feed(level: speech, seconds: 1.0)
        harness.skip(seconds: VoiceSelfAudioEcho.defaultHysteresis + 0.2)
        harness.feed(level: speech, seconds: 0.5)

        XCTAssertEqual(harness.onsets.count, 1)
    }

    /// Suppression clears the stretch rather than pausing it: a run of blocks that is half
    /// TapQ's tail and half the wearer must not be timed as one sound.
    func testSuppressionClearsWhateverWasAccumulating() async {
        let harness = Harness()
        harness.beginListening()

        // 150ms of the wearer — not yet enough — then TapQ starts and speaks over it.
        harness.feed(level: speech, seconds: 0.15)
        harness.voice.beginSpeaking(at: harness.now)
        harness.feed(level: speech, seconds: 0.15)

        XCTAssertEqual(harness.onsets.count, 0,
                       "150ms of wearer plus 150ms of TapQ is not a 300ms utterance")
    }

    // MARK: - Suspension

    func testAPolicyStartsSuspendedAndHearsNothing() async {
        let harness = Harness()
        harness.feed(level: speech, seconds: 3.0)

        XCTAssertTrue(harness.policy.isSuspended)
        XCTAssertEqual(harness.onsets.count, 0)
    }

    func testSamplesArrivingWhileSuspendedAreIgnored() async {
        let harness = Harness()
        harness.beginListening()
        harness.policy.setSuspended(true, at: harness.now)
        harness.feed(level: speech, seconds: 3.0)

        XCTAssertEqual(harness.onsets.count, 0)
    }

    /// A resume arms the hangover from the resume instant. Whatever owned the microphone
    /// through the suspension — a command window — spoke its closing answer through the same
    /// speaker this listener hears, and that answer is still in the room.
    func testAResumeSettlesBeforeItWillFire() async {
        let harness = Harness()
        harness.beginListening()
        harness.policy.setSuspended(true, at: harness.now)
        harness.policy.setSuspended(false, at: harness.now)
        harness.feed(level: speech, seconds: VoiceSelfAudioEcho.defaultHysteresis - 0.1)

        XCTAssertEqual(harness.onsets.count, 0)
    }

    func testAResumeStopsSettlingAfterTheHangover() async {
        let harness = Harness()
        harness.beginListening()
        harness.policy.setSuspended(true, at: harness.now)
        harness.policy.setSuspended(false, at: harness.now)
        harness.skip(seconds: VoiceSelfAudioEcho.defaultHysteresis + 0.2)
        harness.feed(level: speech, seconds: 0.5)

        XCTAssertEqual(harness.onsets.count, 1)
    }

    /// Repeating a suspension state is not an event. The composition calls these from window
    /// lifecycle callbacks, and an idempotent pair is what lets it call them without
    /// bookkeeping of its own.
    func testSuspensionIsIdempotent() async {
        let harness = Harness()
        harness.beginListening()
        harness.beginListening()
        XCTAssertFalse(harness.policy.isSuspended)

        harness.policy.setSuspended(true, at: harness.now)
        harness.policy.setSuspended(true, at: harness.now)
        XCTAssertTrue(harness.policy.isSuspended)
    }

    // MARK: - Configuration

    func testDefaultsAreTheDocumentedNumbers() async {
        let configuration = AcousticAttentionConfiguration()
        XCTAssertEqual(configuration.onsetLevel,
                       AcousticAttentionConfiguration.defaultOnsetLevel)
        XCTAssertEqual(configuration.minimumDuration, 0.20)
        XCTAssertEqual(configuration.gapTolerance, 0.10)
        XCTAssertEqual(configuration.selfAudioHangover,
                       VoiceSelfAudioEcho.defaultHysteresis)
    }

    /// The cooldown has to outlast the window it opens, or the tail of the same sentence
    /// would arm a second window the instant the first one closed.
    func testTheCooldownOutlastsACommandWindow() async {
        XCTAssertGreaterThan(AcousticAttentionConfiguration.defaultCooldown,
                             CommandWindowController.windowSeconds)
    }

    func testAnEmptyEnvironmentResolvesToTheDefaults() async {
        XCTAssertEqual(AcousticAttentionConfiguration.resolved(environment: [:]),
                       AcousticAttentionConfiguration())
    }

    func testTheEnvironmentOverridesEachKnob() async {
        let resolved = AcousticAttentionConfiguration.resolved(environment: [
            AcousticAttentionConfiguration.onsetLevelEnvironmentKey: "0.05",
            AcousticAttentionConfiguration.minimumDurationEnvironmentKey: "350",
            AcousticAttentionConfiguration.cooldownEnvironmentKey: "4000",
        ])
        XCTAssertEqual(resolved.onsetLevel, 0.05, accuracy: 1e-9)
        XCTAssertEqual(resolved.minimumDuration, 0.35, accuracy: 1e-9)
        XCTAssertEqual(resolved.cooldown, 4.0, accuracy: 1e-9)
    }

    /// A misspelled knob must not be why a wearer with no earbuds has no channel at all —
    /// the same fallback `VoiceSelfAudioEcho.resolvedHysteresis` makes.
    func testAnUnreadableEnvironmentValueFallsBack() async {
        let resolved = AcousticAttentionConfiguration.resolved(environment: [
            AcousticAttentionConfiguration.onsetLevelEnvironmentKey: "loud",
            AcousticAttentionConfiguration.minimumDurationEnvironmentKey: "",
            AcousticAttentionConfiguration.cooldownEnvironmentKey: "nan",
        ])
        XCTAssertEqual(resolved, AcousticAttentionConfiguration())
    }

    /// A threshold of zero is a microphone that opens a window at silence. Clamped rather
    /// than obeyed.
    func testOutOfRangeEnvironmentValuesAreClamped() async {
        let resolved = AcousticAttentionConfiguration.resolved(environment: [
            AcousticAttentionConfiguration.onsetLevelEnvironmentKey: "0",
            AcousticAttentionConfiguration.minimumDurationEnvironmentKey: "60000",
            AcousticAttentionConfiguration.cooldownEnvironmentKey: "-1",
        ])
        XCTAssertEqual(resolved.onsetLevel,
                       AcousticAttentionConfiguration.onsetLevelBounds.lowerBound)
        XCTAssertEqual(resolved.minimumDuration,
                       AcousticAttentionConfiguration.minimumDurationBounds.upperBound)
        XCTAssertEqual(resolved.cooldown,
                       AcousticAttentionConfiguration.cooldownBounds.lowerBound)
    }

    /// A tuned configuration is actually the one the policy listens by, rather than a value
    /// it stores and ignores.
    func testATunedConfigurationChangesWhatFires() async {
        let harness = Harness(configuration: AcousticAttentionConfiguration(
            onsetLevel: 0.5,
            minimumDuration: 1.0,
            cooldown: 0
        ))
        harness.beginListening()
        harness.feed(level: speech, seconds: 3.0)
        XCTAssertEqual(harness.onsets.count, 0, "0.08 is below a 0.5 threshold")

        harness.feed(level: quiet, seconds: 0.5)
        harness.feed(level: 0.6, seconds: 0.5)
        XCTAssertEqual(harness.onsets.count, 0, "0.5s is below a 1.0s minimum")

        harness.feed(level: 0.6, seconds: 0.6)
        XCTAssertEqual(harness.onsets.count, 1)
    }

    // MARK: - The status line

    /// The wording an operator reads at startup has to say the property the mode is asking
    /// them to accept, not the mechanism.
    func testTheStatusDescriptionNamesTheWindowAndThePrivacyProperty() async {
        let status = AcousticAttentionPolicy.statusDescription
        XCTAssertTrue(status.hasPrefix("acoustic"), status)
        XCTAssertTrue(
            status.contains("\(Int(CommandWindowController.windowSeconds))s"), status)
        XCTAssertTrue(status.contains("no audio leaves the machine while idle"), status)
    }
}
