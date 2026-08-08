import Foundation

/// Push-driven state holder over `WearerSpeechDetector`. Each ingested motion sample is
/// forwarded to the detector and the resulting state is surfaced through a transition
/// callback. A staleness horizon (defaulting to `config.maxSampleGapSeconds`) lets
/// downstream consumers know whether the most recent answer still describes *now* --
/// a stream that stops arriving (window closed, AirPods asleep) goes stale, and any
/// signal adapter built on top reports `isSignalAvailable == false`.
///
/// All logic lives here so the platform adapter (`WearerSpeechSignalSource`) stays a
/// thin shim.
public final class WearerSpeechMonitor {
    public let config: WearerSpeechConfig

    /// The staleness horizon: if `monotonicNow() - lastSampleAt` exceeds this, the
    /// signal is stale and consumers must fail open.
    public let stalenessHorizon: TimeInterval

    /// The detector's current state.
    public private(set) var state: WearerSpeechState = .quiet

    /// Whether the most recently ingested sample carried per-axis data. Consumers that
    /// need direction-aware analysis (attribution) require this; magnitude-only streams
    /// drive the detector but are not sufficient for attribution.
    public private(set) var lastSampleHadPerAxisData: Bool = false

    /// Monotonic timestamp of the last ingested sample, or nil if no sample has arrived.
    public private(set) var lastSampleAt: TimeInterval?

    /// Whether the stream has been explicitly interrupted (teardown / motion loss).
    public private(set) var interrupted: Bool = false

    /// Fired on every quiet<->speaking transition.
    public var onTransition: ((WearerSpeechTransition) -> Void)?

    private var detector: WearerSpeechDetector
    private let monotonicNow: () -> TimeInterval

    public init(config: WearerSpeechConfig = .init(),
                stalenessHorizon: TimeInterval? = nil,
                monotonicNow: @escaping () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                }) {
        self.config = config
        self.stalenessHorizon = stalenessHorizon ?? config.maxSampleGapSeconds
        self.detector = WearerSpeechDetector(config: config)
        self.monotonicNow = monotonicNow
    }

    /// Feeds one motion sample to the underlying detector and surfaces any transition.
    @discardableResult
    public func ingest(_ sample: HeadMotionSample) -> WearerSpeechUpdate {
        interrupted = false
        lastSampleAt = monotonicNow()
        lastSampleHadPerAxisData = sample.hasPerAxisData
        let update = detector.ingestDetailed(sample)
        state = update.state
        if let transition = update.transition {
            onTransition?(transition)
        }
        return update
    }

    /// Called when the motion stream is interrupted (teardown, motion loss, session
    /// reset). Resets the detector to `.quiet`, marks the signal as stale, and fires a
    /// `stoppedSpeaking` transition if the detector was speaking.
    public func streamInterrupted() {
        interrupted = true
        let wasSpeaking = state == .speaking
        detector.reset()
        state = .quiet
        if wasSpeaking {
            onTransition?(.stoppedSpeaking)
        }
    }

    /// True when the last sample is recent enough to describe the present moment.
    public func isFresh(now: TimeInterval? = nil) -> Bool {
        guard !interrupted, let last = lastSampleAt else { return false }
        let current = now ?? monotonicNow()
        return current - last <= stalenessHorizon
    }
}
