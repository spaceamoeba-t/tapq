import Foundation
import TapQContracts

/// The numbers `--attention acoustic` listens by, and the one place they are written down.
///
/// Every value here is a starting point rather than a measurement. The plan that asked for
/// this rung (docs/VOICE_ONLY_AGENT_PLAN.md §6, gate 5) says the wake phrase is decided from
/// a week of real use rather than upfront, and the same is true of the threshold that would
/// make one necessary — so the three a room actually varies by are readable from the
/// environment, on the convention `TAPQ_SELF_AUDIO_HYSTERESIS_MS` set: a key rather than a
/// flag, because these are properties of a room and a machine and not of a run an operator
/// is composing.
public struct AcousticAttentionConfiguration: Equatable, Sendable {
    /// Root-mean-square amplitude, on the -1…1 float scale the capture tap delivers, at or
    /// above which a block counts as sound worth timing.
    ///
    /// 0.02 is about -34 dBFS. Typical room tone on a Mac's own microphone sits far below
    /// that and a sentence spoken across the same desk sits above it, so this is inside the
    /// gap and deliberately nearer the speech end of it: the failure this feature is judged
    /// on is a window that opens at a chair creak, and a wearer who has to lean in is a
    /// smaller problem than TapQ saying "Yes?" to a closing door. The room this is wrong for
    /// is the room ``onsetLevelEnvironmentKey`` exists for.
    public static let defaultOnsetLevel: Double = 0.02

    /// How long the level has to stay up before the sound is speech rather than a noise.
    ///
    /// 200 ms is about one syllable. What a desk produces — a key, a mug, a chair, a door —
    /// is a transient of a few tens of milliseconds and a decay, and dies well inside it.
    /// The shortest thing a wearer can usefully say does not.
    public static let defaultMinimumDuration: TimeInterval = 0.20

    /// How long the level may sit below the threshold without the sound counting as over.
    ///
    /// Continuous speech is not continuously loud: stop consonants and the seams between
    /// syllables put real silence inside a single word, and a detector that ended the stretch
    /// at the first quiet block would ask the wearer to hold a vowel for a fifth of a second.
    /// 100 ms covers those gaps and not the pause between two sentences.
    ///
    /// Not environment-readable, unlike the three around it: it describes how speech is
    /// shaped rather than how a room sounds, and it is the same shape in every room.
    public static let defaultGapTolerance: TimeInterval = 0.10

    /// How long after an onset the next one is refused.
    ///
    /// Sized off the window an onset opens: ``CommandWindowController/windowSeconds`` of
    /// listening plus a beat for the answer that closes it to drain. A wearer who says a
    /// second sentence while TapQ is still listening to the first is already being heard by
    /// the window; arming again for them would stack a second window behind it, which is the
    /// stacking the IMU path refuses for the same reason.
    public static let defaultCooldown: TimeInterval = CommandWindowController.windowSeconds + 2

    /// RMS threshold, as a bare number in 0…1.
    public static let onsetLevelEnvironmentKey = "TAPQ_ACOUSTIC_ONSET_LEVEL"
    /// ``minimumDuration``, in milliseconds.
    public static let minimumDurationEnvironmentKey = "TAPQ_ACOUSTIC_ONSET_MS"
    /// ``cooldown``, in milliseconds.
    public static let cooldownEnvironmentKey = "TAPQ_ACOUSTIC_COOLDOWN_MS"

    /// Bounds on what the environment may ask for. A mistyped knob is clamped rather than
    /// obeyed, for the reason `VoiceSelfAudioEcho.maximumHysteresis` is clamped: a threshold
    /// of 0 is a microphone that opens a window at silence, and a minimum duration of ten
    /// seconds is always-listening that never listens.
    public static let onsetLevelBounds: ClosedRange<Double> = 0.0005...0.5
    public static let minimumDurationBounds: ClosedRange<TimeInterval> = 0.05...2.0
    public static let cooldownBounds: ClosedRange<TimeInterval> = 0...120

    public let onsetLevel: Double
    public let minimumDuration: TimeInterval
    public let gapTolerance: TimeInterval
    public let cooldown: TimeInterval
    /// How long after TapQ's own voice stops the microphone is still assumed to be hearing
    /// it. The same physical quantity `MicrophonePumpVoiceBackend` suppresses capture on, so
    /// it is the same number: speaker output latency, the room's ring, and the lag in the
    /// signal that reports either.
    public let selfAudioHangover: TimeInterval

    public init(
        onsetLevel: Double = AcousticAttentionConfiguration.defaultOnsetLevel,
        minimumDuration: TimeInterval = AcousticAttentionConfiguration.defaultMinimumDuration,
        gapTolerance: TimeInterval = AcousticAttentionConfiguration.defaultGapTolerance,
        cooldown: TimeInterval = AcousticAttentionConfiguration.defaultCooldown,
        selfAudioHangover: TimeInterval = VoiceSelfAudioEcho.defaultHysteresis
    ) {
        self.onsetLevel = max(0, onsetLevel)
        self.minimumDuration = max(0, minimumDuration)
        self.gapTolerance = max(0, gapTolerance)
        self.cooldown = max(0, cooldown)
        self.selfAudioHangover = max(0, selfAudioHangover)
    }

    /// The configuration this run listens by: the environment where it names a number TapQ
    /// can read, the defaults everywhere else.
    ///
    /// An unreadable value falls back rather than throwing, for the reason
    /// `VoiceSelfAudioEcho.resolvedHysteresis` does: a misspelled tuning knob must not be why
    /// a wearer with no earbuds has no channel at all.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AcousticAttentionConfiguration {
        AcousticAttentionConfiguration(
            onsetLevel: number(environment[onsetLevelEnvironmentKey],
                               scale: 1,
                               bounds: onsetLevelBounds) ?? defaultOnsetLevel,
            minimumDuration: number(environment[minimumDurationEnvironmentKey],
                                    scale: 1_000,
                                    bounds: minimumDurationBounds) ?? defaultMinimumDuration,
            cooldown: number(environment[cooldownEnvironmentKey],
                             scale: 1_000,
                             bounds: cooldownBounds) ?? defaultCooldown
        )
    }

    /// Reads one key, divides by `scale` (1 for a bare number, 1000 for milliseconds), and
    /// clamps. `nil` for anything unreadable, which the caller reads as "use the default".
    private static func number(
        _ raw: String?,
        scale: Double,
        bounds: ClosedRange<Double>
    ) -> Double? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let parsed = Double(trimmed),
              parsed.isFinite else { return nil }
        return min(max(parsed / scale, bounds.lowerBound), bounds.upperBound)
    }
}

/// Decides, from nothing but how loud the room is, when the wearer has started saying
/// something — the free on-device tier of `--attention acoustic`.
///
/// This is the whole of the rung that is not already somebody else's. A persistent capture
/// engine feeds it levels, `CommandWindowController` decides what a window may do once one is
/// open, and the composition decides whether to open one; this decides *that the wearer
/// spoke*, and it is deliberately the only object in the feature that holds a rule. Nothing
/// here touches audio, a microphone, or a network — it consumes a number and a timestamp — so
/// every rule below is checkable with a fake sample stream and no hardware.
///
/// Four guards, each closing a different way for a wearer to be interrupted by TapQ answering
/// a room:
///
/// 1. **Loud enough.** A block under ``AcousticAttentionConfiguration/onsetLevel`` is not
///    sound this feature has an opinion about.
/// 2. **Long enough.** The level has to hold up for ``minimumDuration``, so the transients a
///    desk makes all day are not sentences. A gap shorter than
///    ``AcousticAttentionConfiguration/gapTolerance`` does not break the stretch, because
///    speech has silence inside it.
/// 3. **Once per stretch, then once per cooldown.** A continuous stretch of sound is decided
///    exactly once — the second syllable of a sentence is not a second request for attention
///    — and a stretch that starts again inside the cooldown is the same wearer still talking
///    into a window that is already open.
/// 4. **Never TapQ.** While TapQ's own voice is in the room, and for a hangover after it, the
///    level is TapQ's and is discarded rather than thresholded. There is no threshold that
///    separates them: on a machine with no earbuds TapQ's answer is the loudest thing this
///    microphone will hear all day.
///
/// ## The clock
///
/// There is no clock in here. Every sample carries the instant it was captured, and the
/// policy compares those instants to each other — which is both the honest reading (the
/// level's time is the audio's, not the main actor's) and what makes the timing rules
/// testable by handing them arbitrary numbers.
///
/// ## Why self-audio is a poll and not a subscription
///
/// ``SpeechActivitySignaling/onSpeakingChange`` is a single-observer slot and
/// `SpeechGatedVoice` claims it at composition time; a second assignment would silently
/// disable the self-hearing guard that keeps the microphone shut while TapQ talks. So the
/// question is asked as a *read*, exactly as `VoiceChannelDrain` asks it, and the composition
/// hands over a closure over the same merged engine-plus-player signal the gate itself reads.
@MainActor public final class AcousticAttentionPolicy {
    /// How `--attention acoustic` names itself on the startup status line. It states the
    /// privacy property rather than the mechanism, because that is the property the mode is
    /// asking the operator to accept: the microphone is open, and nothing leaves the machine
    /// until the wearer has actually said something.
    public nonisolated static let statusDescription =
        "acoustic (a local onset opens \(Int(CommandWindowController.windowSeconds))s command"
        + " windows; no audio leaves the machine while idle)"

    public let configuration: AcousticAttentionConfiguration

    /// What TapQ's own voice is doing, read rather than subscribed to. `false` where nothing
    /// renders a voice at all, which is the honest answer for a composition with no speech.
    private let isSelfAudible: @MainActor () -> Bool
    private let diagnostics: TapQDiagnosticEmitter

    /// Fired when the wearer has started saying something. The whole of this object's output.
    ///
    /// Deliberately carries nothing: an onset is the fact that somebody spoke, and a payload
    /// would invite a caller to decide something on the strength of a loudness. What may
    /// happen next is a `CommandWindowController`, which cannot resolve anything either.
    public var onOnset: (@MainActor () -> Void)?

    /// Whether something else owns the microphone right now.
    ///
    /// Starts `true`. A policy that began listening would be timing whatever the audio engine
    /// puts out before it has settled, and the composition has to say the engine is up
    /// anyway — so the un-suspend that starts listening and the one that ends a window are
    /// the same call, and the settling below covers both.
    public private(set) var isSuspended = true

    /// Onsets fired since init. For diagnostics and tests.
    public private(set) var onsetCount = 0

    /// When the current stretch of above-threshold sound began, or `nil` between stretches.
    private var soundStartedAt: TimeInterval?
    /// The most recent above-threshold instant inside the current stretch, which is what the
    /// gap tolerance is measured from.
    private var lastLoudAt: TimeInterval?
    /// Whether the current stretch has already been decided. One decision per stretch, so a
    /// sentence that keeps going does not keep asking.
    private var stretchDecided = false
    /// When the last onset fired, which the cooldown is measured from.
    private var lastOnsetAt: TimeInterval?
    /// The last instant TapQ's own voice was known to be in the room. Written from two
    /// places: any sample at which the signal said so, and the instant a suspension ended.
    private var selfAudibleAt: TimeInterval?

    /// Samples discarded as TapQ's own voice since the last one that got through.
    ///
    /// Counted rather than logged: blocks arrive every twenty-odd milliseconds, and a line
    /// per block would bury the run's log in the middle of whatever an operator opened it
    /// for. The pump counts its own suppression the same way and for the same reason.
    private var suppressedSamples = 0

    public init(
        configuration: AcousticAttentionConfiguration = .resolved(),
        isSelfAudible: @escaping @MainActor () -> Bool = { false },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.configuration = configuration
        self.isSelfAudible = isSelfAudible
        self.diagnostics = TapQDiagnosticEmitter(category: "Acoustic", sink: diagnosticSink)
    }

    /// One capture block's loudness, stamped with the instant it was captured.
    ///
    /// Samples arriving while suspended are dropped without being counted: the microphone
    /// belongs to something else, and what that something heard is not this object's to
    /// interpret.
    public func noteLevel(_ rms: Double, at instant: TimeInterval) {
        guard !isSuspended else { return }

        if isSelfAudible() {
            selfAudibleAt = instant
        }
        if let selfAudibleAt, instant <= selfAudibleAt + configuration.selfAudioHangover {
            suppressedSamples += 1
            // Whatever was accumulating was TapQ. Cleared rather than paused, so a stretch
            // cannot be half TapQ's voice and half the wearer's.
            endStretch()
            return
        }
        flushSuppression()

        guard rms >= configuration.onsetLevel else {
            // Below the threshold. The stretch ends only once the gap has outlasted the
            // tolerance — speech goes quiet inside a word, and a sentence is not over
            // because a consonant was.
            if let lastLoudAt, instant > lastLoudAt + configuration.gapTolerance {
                endStretch()
            }
            return
        }

        lastLoudAt = instant
        guard !stretchDecided else { return }
        let startedAt = soundStartedAt ?? instant
        soundStartedAt = startedAt
        let held = instant - startedAt
        guard held >= configuration.minimumDuration else { return }

        stretchDecided = true
        decide(at: instant, level: rms, held: held)
    }

    /// Hands the microphone over, or takes it back.
    ///
    /// Suspending is what the composition does when a command window opens: the window's own
    /// capture is the live one, and two engines on one input device is a cost with nothing to
    /// buy. Resuming arms the self-audio hangover from `instant` rather than trusting what
    /// was recorded before the suspension — whatever owned the microphone in between spoke
    /// through the same speaker this one listens to, and the tail of its last sentence is
    /// still in the room. That is also what makes the very first resume, the one that starts
    /// the run listening, wait out the engine settling.
    public func setSuspended(_ suspended: Bool, at instant: TimeInterval) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        endStretch()
        flushSuppression()
        if suspended {
            diagnostics.record("listening.suspended")
        } else {
            selfAudibleAt = instant
            diagnostics.record("listening.resumed")
        }
    }

    // MARK: - Internals

    private func decide(at instant: TimeInterval, level: Double, held: TimeInterval) {
        if let lastOnsetAt, instant < lastOnsetAt + configuration.cooldown {
            diagnostics.record("onset.ignored_cooldown", fields: [
                "since_ms": Self.milliseconds(instant - lastOnsetAt),
            ])
            return
        }
        let previous = lastOnsetAt
        lastOnsetAt = instant
        onsetCount += 1
        var fields = [
            "level": Self.amplitude(level),
            "held_ms": Self.milliseconds(held),
        ]
        if let previous {
            fields["since_previous_ms"] = Self.milliseconds(instant - previous)
        }
        diagnostics.record("onset", fields: fields)
        onOnset?()
    }

    private func endStretch() {
        soundStartedAt = nil
        lastLoudAt = nil
        stretchDecided = false
    }

    /// Reports one stretch of discarded capture, once, when the gate opens again.
    private func flushSuppression() {
        guard suppressedSamples > 0 else { return }
        diagnostics.record("onset.suppressed_self_audio", fields: [
            "samples": "\(suppressedSamples)",
        ])
        suppressedSamples = 0
    }

    private nonisolated static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1_000).rounded()))"
    }

    private nonisolated static func amplitude(_ level: Double) -> String {
        String(format: "%.4f", level)
    }
}
