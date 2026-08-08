import Foundation

/// One window's worth of wearer-speech evidence, plus the reason it was rejected.
/// Mirrors `TapAnalysis`: the decision and the numbers behind it are produced together so
/// diagnostics never re-derive (and never drift from) the policy.
public struct WearerSpeechAnalysis: Sendable, Equatable {
    public enum Rejection: String, Sendable, Equatable {
        case insufficientSamples = "insufficient_samples"
        case belowEnvelope = "below_envelope"
        case rotationNotQuiet = "rotation_not_quiet"
        case tooBrief = "too_brief"
    }

    public let rejection: Rejection?
    public let envelopeSamples: Int
    public let rotationSamples: Int
    /// Largest per-sample jerk in the window (g).
    public let peakEnvelope: Double
    /// Samples in the window at or above `threshold`.
    public let elevatedSamples: Int
    /// `elevatedSamples / envelopeSamples`; 0 for an empty window.
    public let activeFraction: Double
    public let maximumRotation: Double
    /// The hysteresis threshold actually applied — enter while quiet, exit while speaking.
    public let threshold: Double
    /// How long the window has been continuously active up to this sample.
    public let sustainedSeconds: TimeInterval

    public var detected: Bool { rejection == nil }

    /// Same window evidence, with the duration gate's verdict folded in.
    fileprivate func timed(sustainedSeconds: TimeInterval,
                           rejection: Rejection? = nil) -> WearerSpeechAnalysis {
        WearerSpeechAnalysis(
            rejection: rejection ?? self.rejection,
            envelopeSamples: envelopeSamples,
            rotationSamples: rotationSamples,
            peakEnvelope: peakEnvelope,
            elevatedSamples: elevatedSamples,
            activeFraction: activeFraction,
            maximumRotation: maximumRotation,
            threshold: threshold,
            sustainedSeconds: sustainedSeconds
        )
    }
}

/// Pure wearer-speech detector over a trailing window of jerk-envelope and rotation
/// magnitudes. Separated from CoreMotion (and from `MotionGesturePipeline`'s windows) so
/// the logic is unit-testable with synthetic data, mirroring `TapAnalyzer`.
///
/// Physical rationale: speech is transmitted to an in-ear IMU through the jaw and skull,
/// not through the air. The bone-conducted component reaching the earbud is a continuous
/// low-amplitude tremor for as long as the wearer is talking. The motion stream is only
/// 25 Hz, so its Nyquist limit (~12.5 Hz) sits below the voiced fundamental — none of the
/// speech *band* survives sampling. What does survive is its aliased residue: a sustained
/// modest elevation of the sample-to-sample change in user acceleration. That residue,
/// not a spectrum, is what this analyzer measures, which is why the thresholds are
/// empirical config rather than derived constants.
///
/// A window counts as wearer speech when:
///   1. it holds enough samples to judge,
///   2. some sample clears the hysteresis threshold (something is vibrating at all),
///   3. max `|rot|` stays under `rotationQuiet` — the head is not being nodded or shaken,
///      whose turnarounds produce a speech-sized envelope, and
///   4. the elevation is *broad* (`minimumActiveFraction` of the window) and has been
///      sustained for `minimumSpeakingSeconds` — the exact inverse of `TapAnalyzer`'s
///      brevity gate, and what rejects an impact: a tap elevates one or two samples.
public struct WearerSpeechAnalyzer {
    public let config: WearerSpeechConfig

    public init(config: WearerSpeechConfig = .init()) {
        self.config = config
    }

    /// The jerk envelope contributed by one sample, given its predecessor: the change in
    /// user acceleration, in g. When both samples carry signed per-axis data the vector
    /// difference is used (it sees direction reversals that leave the magnitude
    /// unchanged); magnitude-only adapters fall back to the change in
    /// `accelerationMagnitude`.
    ///
    /// The two paths do not share a scale — the vector difference is greater than or equal
    /// to the scalar one — so a calibration profile is only valid for streams from the same
    /// kind of adapter. `WearerSpeechCalibrator` computes its envelope through this same
    /// function for exactly that reason.
    ///
    /// The difference is deliberately *not* divided by `dt`: at a fixed 25 Hz that only
    /// rescales every value by the same constant, and keeping the units in g keeps the
    /// thresholds comparable with `TapConfig.amplitudeThreshold`.
    static func envelopeValue(from previous: HeadMotionSample,
                              to sample: HeadMotionSample) -> Double {
        guard previous.hasPerAxisData, sample.hasPerAxisData else {
            return abs(sample.accelerationMagnitude - previous.accelerationMagnitude)
        }
        let a = sample.userAcceleration
        let b = previous.userAcceleration
        return MotionVector(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z).magnitude
    }

    /// Envelope values for a whole recorded phase, oldest first. Yields `samples.count - 1`
    /// values for a contiguous stream; pairs separated by more than `maximumGapSeconds`
    /// (or out of order) are skipped rather than differenced across the discontinuity,
    /// matching `WearerSpeechDetector`'s live gap policy.
    static func envelopeSeries(
        _ samples: [HeadMotionSample],
        maximumGapSeconds: TimeInterval = WearerSpeechConfig.defaultMaximumSampleGapSeconds
    ) -> [Double] {
        guard samples.count > 1 else { return [] }
        var values: [Double] = []
        values.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let sample = samples[index]
            let delta = sample.timestamp - previous.timestamp
            guard delta > 0, delta <= maximumGapSeconds else { continue }
            values.append(envelopeValue(from: previous, to: sample))
        }
        return values
    }

    /// Level, breadth and rotation gates over the window. Duration-independent, so the
    /// caller can use one evaluation both to maintain its "active since" clock and to
    /// decide. `holding` is true while the detector is already reporting speech, and
    /// selects the lower (exit) half of the hysteresis pair.
    func windowActivity(envelope: [Double], rotation: [Double],
                        holding: Bool) -> WearerSpeechAnalysis {
        let threshold = holding ? config.envelopeExitThreshold : config.envelopeEnterThreshold
        let peak = envelope.max() ?? 0
        let maximumRotation = rotation.max() ?? 0
        let elevated = envelope.lazy.filter { $0 >= threshold }.count
        let activeFraction = envelope.isEmpty ? 0 : Double(elevated) / Double(envelope.count)

        let rejection: WearerSpeechAnalysis.Rejection?
        if envelope.count < config.minSamples || rotation.count < config.minSamples {
            rejection = .insufficientSamples
        } else if peak < threshold {
            rejection = .belowEnvelope
        } else if maximumRotation >= config.rotationQuiet {
            // Windowed rotation gate: a nod or shake carries a speech-sized envelope, and
            // its quiet turnaround sample is flanked by high rotation.
            rejection = .rotationNotQuiet
        } else if activeFraction < config.minimumActiveFraction {
            // Breadth: an impact is a transient, speech fills the window.
            rejection = .tooBrief
        } else {
            rejection = nil
        }

        return WearerSpeechAnalysis(
            rejection: rejection,
            envelopeSamples: envelope.count,
            rotationSamples: rotation.count,
            peakEnvelope: peak,
            elevatedSamples: elevated,
            activeFraction: activeFraction,
            maximumRotation: maximumRotation,
            threshold: threshold,
            sustainedSeconds: 0
        )
    }

    /// Applies the onset-duration gate to a window that already passed `windowActivity`.
    /// The gate is skipped while `holding`: once speech has been declared, staying in it
    /// must not re-serve the onset delay on every sample.
    func applyDurationGate(to activity: WearerSpeechAnalysis,
                           sustainedSeconds: TimeInterval,
                           holding: Bool) -> WearerSpeechAnalysis {
        guard activity.detected, !holding,
              sustainedSeconds < config.minimumSpeakingSeconds - Self.durationEpsilon else {
            return activity.timed(sustainedSeconds: sustainedSeconds)
        }
        return activity.timed(sustainedSeconds: sustainedSeconds, rejection: .tooBrief)
    }

    /// Full window decision. `sustainedSeconds` is how long the window has been
    /// continuously active; `WearerSpeechDetector` tracks it across samples.
    func analyze(envelope: [Double], rotation: [Double],
                 sustainedSeconds: TimeInterval, holding: Bool) -> WearerSpeechAnalysis {
        applyDurationGate(
            to: windowActivity(envelope: envelope, rotation: rotation, holding: holding),
            sustainedSeconds: sustainedSeconds,
            holding: holding
        )
    }

    /// True when the window ends in wearer speech.
    public func detect(envelope: [Double], rotation: [Double],
                       sustainedSeconds: TimeInterval, holding: Bool) -> Bool {
        analyze(envelope: envelope, rotation: rotation,
                sustainedSeconds: sustainedSeconds, holding: holding).detected
    }

    /// Duration comparisons run against timestamps accumulated by repeated addition at
    /// 25 Hz, so a sample landing exactly on the minimum must not be lost to rounding.
    private static let durationEpsilon: TimeInterval = 1e-9
}

/// Whether the wearer is currently judged to be speaking.
public enum WearerSpeechState: String, Sendable, Equatable {
    case quiet
    case speaking
}

/// State change produced by a single ingested sample.
public enum WearerSpeechTransition: String, Sendable, Equatable {
    case startedSpeaking = "started_speaking"
    case stoppedSpeaking = "stopped_speaking"
}

/// Everything one ingested sample produced: the resulting state, the transition it caused
/// (if any), the sample's own envelope contribution, and the window analysis behind the
/// decision.
public struct WearerSpeechUpdate: Sendable, Equatable {
    public let state: WearerSpeechState
    public let transition: WearerSpeechTransition?
    /// This sample's jerk contribution (g); 0 for the first sample of a stream and for the
    /// sample that follows a gap, neither of which has a usable predecessor.
    public let envelope: Double
    public let analysis: WearerSpeechAnalysis
    /// True while `state == .speaking` only because the hangover has not yet expired.
    public let inHangover: Bool

    public var isSpeaking: Bool { state == .speaking }
}

/// Stateful, hardware-independent wearer-speech detector. It owns the trailing envelope
/// and rotation windows, the hysteresis state, the onset clock and the hangover;
/// `WearerSpeechAnalyzer` stays pure.
///
/// This is a *separate consumer* of the same `HeadMotionSample` stream as
/// `MotionGesturePipeline` and deliberately shares no window state with it: the two answer
/// different questions over different time scales, and coupling them would make one's
/// window-consumption policy silently change the other's decisions.
public struct WearerSpeechDetector {
    public var config: WearerSpeechConfig {
        didSet { analyzer = WearerSpeechAnalyzer(config: config) }
    }

    /// The current decision. Also readable between ingests, for signal adapters.
    public private(set) var state: WearerSpeechState = .quiet

    private var analyzer: WearerSpeechAnalyzer
    private var envelope: [(time: TimeInterval, value: Double)] = []
    private var rotation: [(time: TimeInterval, value: Double)] = []
    private var previous: HeadMotionSample?
    /// When the window most recently became active, or nil while it is inactive.
    private var activeSince: TimeInterval?
    /// Timestamp of the last active window, used to time the hangover.
    private var lastActiveAt: TimeInterval?

    public init(config: WearerSpeechConfig = .init()) {
        self.config = config
        self.analyzer = WearerSpeechAnalyzer(config: config)
    }

    /// Clears all temporal state and returns to `.quiet`, retaining configuration.
    /// Mirrors `MotionGesturePipeline.reset()`; called automatically on a stream gap.
    public mutating func reset() {
        envelope.removeAll()
        rotation.removeAll()
        previous = nil
        activeSince = nil
        lastActiveAt = nil
        state = .quiet
    }

    /// Feeds one sample and reports the resulting state.
    @discardableResult
    public mutating func ingest(_ sample: HeadMotionSample) -> WearerSpeechState {
        ingestDetailed(sample).state
    }

    /// Feeds one sample and reports the state, the transition and the evidence.
    @discardableResult
    public mutating func ingestDetailed(_ sample: HeadMotionSample) -> WearerSpeechUpdate {
        let previousState = state

        // A discontinuity in the stream (dropped samples, a stopped and restarted capture,
        // a replay seeking) must not be differenced: the jump would read as one enormous
        // jerk, and the retained window describes a stretch of time that no longer
        // adjoins this sample. Start over instead.
        if let last = previous {
            let delta = sample.timestamp - last.timestamp
            if delta <= 0 || delta > config.maxSampleGapSeconds {
                reset()
            }
        }

        guard let last = previous else {
            // First sample of a stream: nothing to difference against yet.
            previous = sample
            return finish(previousState: previousState, envelope: 0,
                          analysis: emptyAnalysis(holding: previousState == .speaking))
        }

        let value = WearerSpeechAnalyzer.envelopeValue(from: last, to: sample)
        previous = sample
        envelope.append((sample.timestamp, value))
        rotation.append((sample.timestamp, sample.rotationMagnitude))
        let cutoff = sample.timestamp - config.windowSeconds
        envelope.removeAll { $0.time < cutoff }
        rotation.removeAll { $0.time < cutoff }

        let holding = state == .speaking
        let activity = analyzer.windowActivity(
            envelope: envelope.map(\.value),
            rotation: rotation.map(\.value),
            holding: holding
        )

        if activity.detected {
            if activeSince == nil { activeSince = sample.timestamp }
            lastActiveAt = sample.timestamp
        } else {
            activeSince = nil
        }
        let sustained = activeSince.map { sample.timestamp - $0 } ?? 0

        let analysis = analyzer.applyDurationGate(
            to: activity, sustainedSeconds: sustained, holding: holding
        )

        var inHangover = false
        if analysis.detected {
            state = .speaking
        } else if holding,
                  let lastActiveAt,
                  sample.timestamp - lastActiveAt <= config.hangoverSeconds {
            // Hangover: an inter-word pause is not the end of an utterance.
            inHangover = true
        } else {
            state = .quiet
        }

        return finish(previousState: previousState, envelope: value,
                      analysis: analysis, inHangover: inHangover)
    }

    private func emptyAnalysis(holding: Bool) -> WearerSpeechAnalysis {
        analyzer.windowActivity(envelope: [], rotation: [], holding: holding)
    }

    private func finish(previousState: WearerSpeechState, envelope: Double,
                        analysis: WearerSpeechAnalysis,
                        inHangover: Bool = false) -> WearerSpeechUpdate {
        let transition: WearerSpeechTransition?
        switch (previousState, state) {
        case (.quiet, .speaking): transition = .startedSpeaking
        case (.speaking, .quiet): transition = .stoppedSpeaking
        default: transition = nil
        }
        return WearerSpeechUpdate(
            state: state,
            transition: transition,
            envelope: envelope,
            analysis: analysis,
            inHangover: inHangover
        )
    }
}
