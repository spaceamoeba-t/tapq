import Foundation

/// Tunable thresholds for wearer-speech detection from the earbud IMU.
///
/// The detected quantity is a *jerk envelope*: the sample-to-sample change in user
/// acceleration, in g. While the wearer talks, jaw motion and skull-borne vibration keep
/// that envelope modestly but continuously elevated, whereas an impact (tap) elevates it
/// for one or two samples and a nod/shake elevates it together with high rotation rate.
/// The three gates below — level, sustain, rotation quiet — are what separate those cases.
///
/// Every default here is a provisional uncalibrated starting point: the 25 Hz CoreMotion
/// stream has never been characterised against ground-truth speech, so the capture study
/// retunes these values and `WearerSpeechCalibrator` writes them into a saved profile.
/// Retuning must stay a data change, never a code change.
public struct WearerSpeechConfig: Sendable, Codable, Equatable {
    /// Default maximum inter-sample gap; also the gap policy used by
    /// `WearerSpeechAnalyzer.envelopeSeries` when no explicit value is supplied.
    public static let defaultMaximumSampleGapSeconds: TimeInterval = 0.5

    /// Envelope level (g, per-sample jerk) a sample must reach to count as "elevated"
    /// while the detector is *quiet*. The higher half of the hysteresis pair.
    public var envelopeEnterThreshold: Double
    /// Envelope level a sample must reach to keep counting as elevated once the detector
    /// is *speaking*. Deliberately lower than the enter threshold so a stream hovering in
    /// the mid band settles in whichever state it is already in instead of chattering.
    public var envelopeExitThreshold: Double
    /// Fraction of the trailing window that must be elevated before the window counts as
    /// active. This is the gate that rejects impacts: a tap elevates one or two samples of
    /// a ~15-sample window, speech elevates most of it.
    public var minimumActiveFraction: Double
    /// How long the window must stay continuously active before `.quiet` becomes
    /// `.speaking`. Onset latency is roughly this plus the time to fill
    /// `minimumActiveFraction` of the window.
    public var minimumSpeakingSeconds: TimeInterval
    /// How long `.speaking` survives an inactive window. Covers the natural gaps between
    /// words and phrases so one utterance does not fragment into many.
    public var hangoverSeconds: TimeInterval
    /// The window's maximum `|rotationRate|` (rad/s) must stay below this. Windowed, not
    /// instantaneous, exactly like `TapConfig.rotationQuiet`: a nod or shake produces a
    /// speech-sized acceleration envelope, and only the rotation gate tells them apart.
    public var rotationQuiet: Double
    /// Trailing window over which the envelope level and rotation are judged.
    public var windowSeconds: TimeInterval
    /// Minimum envelope samples in the window before attempting detection.
    public var minSamples: Int
    /// Two consecutive samples further apart than this are not differenced: the stream was
    /// interrupted, so the detector resets rather than reading the discontinuity as a
    /// vibration burst.
    public var maxSampleGapSeconds: TimeInterval

    public init(
        envelopeEnterThreshold: Double = 0.020,
        envelopeExitThreshold: Double = 0.012,
        minimumActiveFraction: Double = 0.5,
        minimumSpeakingSeconds: TimeInterval = 0.3,
        hangoverSeconds: TimeInterval = 0.6,
        rotationQuiet: Double = 0.8,
        windowSeconds: TimeInterval = 0.6,
        minSamples: Int = 6,
        maxSampleGapSeconds: TimeInterval = WearerSpeechConfig.defaultMaximumSampleGapSeconds
    ) {
        self.envelopeEnterThreshold = envelopeEnterThreshold
        self.envelopeExitThreshold = envelopeExitThreshold
        self.minimumActiveFraction = minimumActiveFraction
        self.minimumSpeakingSeconds = minimumSpeakingSeconds
        self.hangoverSeconds = hangoverSeconds
        self.rotationQuiet = rotationQuiet
        self.windowSeconds = windowSeconds
        self.minSamples = minSamples
        self.maxSampleGapSeconds = maxSampleGapSeconds
    }

    /// Tolerant decoding, per `HeadGestureConfig`'s policy: the two calibrated envelope
    /// thresholds are the payload a saved profile exists to carry and stay required, while
    /// every shape knob falls back to its default. A profile written before a knob existed
    /// must keep loading — silently discarding a calibration is worse than running one
    /// knob at its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WearerSpeechConfig()
        envelopeEnterThreshold = try c.decode(Double.self, forKey: .envelopeEnterThreshold)
        envelopeExitThreshold = try c.decode(Double.self, forKey: .envelopeExitThreshold)
        minimumActiveFraction = try c.decodeIfPresent(Double.self, forKey: .minimumActiveFraction)
            ?? defaults.minimumActiveFraction
        minimumSpeakingSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .minimumSpeakingSeconds)
            ?? defaults.minimumSpeakingSeconds
        hangoverSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .hangoverSeconds)
            ?? defaults.hangoverSeconds
        rotationQuiet = try c.decodeIfPresent(Double.self, forKey: .rotationQuiet)
            ?? defaults.rotationQuiet
        windowSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .windowSeconds)
            ?? defaults.windowSeconds
        minSamples = try c.decodeIfPresent(Int.self, forKey: .minSamples)
            ?? defaults.minSamples
        maxSampleGapSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .maxSampleGapSeconds)
            ?? defaults.maxSampleGapSeconds
    }
}
