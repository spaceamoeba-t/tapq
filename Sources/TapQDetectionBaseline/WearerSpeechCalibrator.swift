import Foundation

/// Jerk-envelope values captured during a wearer-speech calibration: a few seconds of
/// silence followed by a few seconds of the wearer reading aloud with the head still.
///
/// The envelope is always produced by `WearerSpeechAnalyzer.envelopeValue`, the same
/// function `WearerSpeechDetector` runs live. Anything else would calibrate one quantity
/// and detect another — and the per-axis and magnitude-only paths do not even share a
/// scale, so a profile is only valid for streams from the kind of adapter that recorded it.
public struct WearerSpeechCalibrationSamples: Sendable, Equatable {
    /// Envelope values from the quiet phase, in g.
    public var restingEnvelope: [Double]
    /// Envelope values from the read-aloud phase, in g.
    public var speakingEnvelope: [Double]

    public init(restingEnvelope: [Double] = [], speakingEnvelope: [Double] = []) {
        self.restingEnvelope = restingEnvelope
        self.speakingEnvelope = speakingEnvelope
    }

    /// Differences two recorded phases into envelope series. Pairs straddling a stream gap
    /// are dropped rather than differenced, matching the detector's live gap policy, so a
    /// dropped-sample discontinuity cannot be calibrated against as if it were speech.
    public init(
        resting: [HeadMotionSample],
        speaking: [HeadMotionSample],
        maximumGapSeconds: TimeInterval = WearerSpeechConfig.defaultMaximumSampleGapSeconds
    ) {
        self.init(
            restingEnvelope: WearerSpeechAnalyzer.envelopeSeries(
                resting, maximumGapSeconds: maximumGapSeconds),
            speakingEnvelope: WearerSpeechAnalyzer.envelopeSeries(
                speaking, maximumGapSeconds: maximumGapSeconds)
        )
    }
}

/// Pure wearer-speech calibration: given a quiet phase and a read-aloud phase, suggest the
/// hysteresis pair in `WearerSpeechConfig` that sits above this wearer's resting jitter and
/// below the level their own speech sustains. Stateless and CoreMotion-free, mirroring
/// `TapCalibrator`.
///
/// The statistics differ from `TapCalibrator`'s on purpose, because the physical events do.
/// A tap is one impulse, so its *peak* is the signal. Speech is a continuous tremor, so its
/// peak is a syllable onset — a tap-shaped value that would set the threshold far too high
/// for the detector's breadth gate (`minimumActiveFraction`) to ever pass. The speaking
/// statistic is therefore the median: the level at least half the speaking samples hold.
/// Rest keeps the peak, because a threshold has to clear the *worst* of the quiet phase,
/// not its typical value.
public enum WearerSpeechCalibrator {
    /// Fraction of the wearer's sustained speaking level the enter threshold is set to.
    /// Below 1 so comfortably more than half of speaking samples clear it, which is what
    /// `WearerSpeechConfig.minimumActiveFraction` (0.5 by default) asks of the window.
    static let speakingFraction = 0.6
    /// A saved enter threshold must clear the resting envelope peak by this multiple.
    static let thresholdRestingHeadroom = 2.0
    /// Calibration acceptance is stricter than the saved threshold, exactly as in
    /// `TapCalibrator`: the observed speech must be this far clear of rest before it can
    /// be trusted to tune anything.
    static let usabilityRestingHeadroom = 3.0
    /// The exit half of the hysteresis pair as a fraction of the enter half. The gap is
    /// what stops a stream hovering at threshold from chattering between states.
    static let exitFraction = 0.7
    /// The exit threshold must also stay this far above resting noise. Without the floor a
    /// quiet-but-not-silent baseline could hold the detector in `.speaking` indefinitely,
    /// since leaving the state requires the envelope to fall *below* exit.
    static let exitRestingHeadroom = 1.5
    /// Hard ceiling on exit relative to enter, so a degenerate capture can never collapse
    /// the hysteresis gap (or invert it) no matter how the floors interact.
    static let maxExitFraction = 0.9
    /// Absolute clamp, in g of per-sample jerk. The floor stops an unusually still
    /// baseline from producing a profile that reads room vibration as speech; the ceiling
    /// keeps ordinary speech detectable.
    static let minThreshold = 0.004
    static let maxThreshold = 0.20
    /// Even against a silent baseline, require a measurable sustained tremor. The 25 Hz
    /// stream's own quantisation noise lives below this.
    static let minUsableSpeaking = 0.006
    /// Samples required in each phase before a calibration means anything: half a second
    /// at 25 Hz. A one-sample phase has no median worth the name.
    static let minimumSampleCount = 12

    /// Explains both the observed separation and the floor used to accept or reject it, so
    /// the CLI can print why a calibration failed without re-deriving the policy.
    public struct Assessment: Sendable, Equatable {
        /// Largest per-sample jerk observed while quiet (g).
        public let restingEnvelopePeak: Double
        /// Median per-sample jerk observed while speaking (g) — the level the wearer's
        /// speech *sustains*, not the loudest instant of it.
        public let speakingEnvelopeLevel: Double
        public let requiredLevel: Double
        public let restingSampleCount: Int
        public let speakingSampleCount: Int

        /// Envelope values each phase needs before it can be summarised. Carried on the
        /// assessment so a caller can say how short a capture fell without reaching for
        /// the calibrator's own constants.
        public var requiredSampleCount: Int { minimumSampleCount }

        /// Both phases produced enough envelope values to summarise.
        public var hasEnoughSamples: Bool {
            restingSampleCount >= requiredSampleCount
                && speakingSampleCount >= requiredSampleCount
        }

        public var isUsable: Bool {
            hasEnoughSamples && speakingEnvelopeLevel >= requiredLevel
        }
    }

    public static func assessment(
        of samples: WearerSpeechCalibrationSamples
    ) -> Assessment {
        let restingPeak = samples.restingEnvelope.max() ?? 0
        let speakingLevel = median(samples.speakingEnvelope)
        return Assessment(
            restingEnvelopePeak: restingPeak,
            speakingEnvelopeLevel: speakingLevel,
            requiredLevel: max(minUsableSpeaking, restingPeak * usabilityRestingHeadroom),
            restingSampleCount: samples.restingEnvelope.count,
            speakingSampleCount: samples.speakingEnvelope.count
        )
    }

    /// Derives a config from captured envelopes, preserving every field of `base` except
    /// the two thresholds. If no speaking samples were captured, returns `base` unchanged.
    public static func suggestedConfig(
        from samples: WearerSpeechCalibrationSamples,
        base: WearerSpeechConfig = .init()
    ) -> WearerSpeechConfig {
        guard !samples.speakingEnvelope.isEmpty else { return base }
        let restingPeak = samples.restingEnvelope.max() ?? 0

        let fromSpeech = median(samples.speakingEnvelope) * speakingFraction
        let raised = max(fromSpeech, restingPeak * thresholdRestingHeadroom)
        let enter = min(max(raised, minThreshold), maxThreshold)
        let exit = min(
            max(enter * exitFraction, restingPeak * exitRestingHeadroom),
            enter * maxExitFraction
        )

        var config = base
        config.envelopeEnterThreshold = enter
        config.envelopeExitThreshold = exit
        return config
    }

    /// Whether the captured speech is sustained enough, and separated enough from resting
    /// noise, that the suggested thresholds can be trusted.
    public static func isSpeechUsable(_ samples: WearerSpeechCalibrationSamples) -> Bool {
        assessment(of: samples).isUsable
    }

    /// Lower median of the values, or 0 when there are none. The lower median rather than
    /// an interpolated one so the statistic is always a value the wearer actually produced.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }
}
