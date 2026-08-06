import Foundation

/// One head-gesture session: the detectors composed, configured, and fanned into a single
/// event stream.
///
/// `GestureSession` owns no detection logic of its own. It wires `HeadGestureDetector`
/// (nods, shakes, taps, tilts, experimental motion swipes, motion loss/recovery) and
/// `VolumeSwipeDetector` (stem swipes, macOS only) to one callback or one `AsyncStream`,
/// and applies a `Configuration` to them. Anything it reports is produced by those
/// detectors and by the portable analyzers underneath them; if you need to change *how* a
/// gesture is judged, reach past this type into the raw tier.
///
/// ```swift
/// let session = GestureSession(configuration: .calibrated(from: CalibrationStore.defaultStore()))
/// for await event in session.events() {
///     switch event {
///     case .headGesture(.nod): approve()
///     case .headGesture(.shake): reject()
///     case .motionLost: showReconnectHint()
///     default: break
///     }
/// }
/// ```
///
/// ## Curated and raw are mutually exclusive
///
/// A session either delivers `GestureEvent`s (`start(onEvent:)` / `events()`) or raw
/// `HeadMotionSample`s (`motionSamples()`) — never both. This is the underlying detector's
/// constraint: one CoreMotion subscription is either being classified or being handed
/// through unclassified, and a second `CMHeadphoneMotionManager` would contend with the
/// first. Asking for the mode that is not active is not a programmer error and does not
/// trap: it records a diagnostic and hands back a stream that finishes immediately. To
/// capture *and* detect, `stop()` first, or use two sessions on two sources.
@MainActor public final class GestureSession {

    /// What the session's detectors are configured with. Value type: build one, hand it to
    /// an init, and read it back from `configuration`.
    ///
    /// Every field maps to a property the underlying detectors already expose — this is
    /// not a parallel tuning model. The four config structs come from the raw tier and
    /// carry their own physical documentation.
    public struct Configuration: Sendable {
        /// Nod/shake thresholds and pairing windows. Tuned by gesture calibration.
        public var gestures: HeadGestureConfig = .init()
        /// Tap amplitude, rotation-quiet gate, and pairing windows. Tuned by tap calibration.
        public var taps: TapConfig = .init()
        /// Lateral (roll-axis) double-tilt thresholds.
        public var tilts: TiltConfig = .init()
        /// Experimental motion-swipe thresholds; inert unless `motionSwipeDetectionEnabled`.
        public var swipes: SwipeConfig = .init()
        /// Whether the tap channel runs. On by default.
        public var tapDetectionEnabled: Bool = true
        /// Whether the experimental motion-swipe channel runs. Off by default until the
        /// capture study confirms direction separability at the ~25 Hz sample rate.
        public var motionSwipeDetectionEnabled: Bool = false
        /// Whether the session listens to system output volume for stem swipes. Ignored
        /// where no volume-swipe source exists (non-macOS, or none injected).
        public var volumeSwipesEnabled: Bool = true

        public init() {}

        /// Defaults overlaid with whatever calibration the store holds.
        ///
        /// Absent, unreadable, and schema-rejected profiles are all silently treated as
        /// "not calibrated" and leave that half of the configuration at its defaults —
        /// the same rule the `tapq` CLI applies, and the reason a corrupt tap profile can
        /// never cost you working nod/shake detection. Check `store.exists(_:)` yourself
        /// if you want to *tell* the user they are running uncalibrated.
        public static func calibrated(from store: any CalibrationProfileStoring) -> Configuration {
            var configuration = Configuration()
            if store.exists(.gesture), let profile = try? store.loadGesture() {
                configuration.gestures = profile.config
            }
            if store.exists(.tap), let profile = try? store.loadTap() {
                configuration.taps = profile.config
            }
            return configuration
        }
    }

    /// Which tier is currently streaming. See the type's mutual-exclusion note.
    private enum Mode {
        case idle
        case curated
        case raw
    }

    /// The configuration the session was built with and applied to its detectors.
    public private(set) var configuration: Configuration

    /// What this host can detect right now. Re-read it after a headphone connect or
    /// disconnect; it is a live query, not a snapshot taken at init.
    public var capabilities: GestureCapabilities { .current() }

    private let detector: HeadGestureDetector
    private let volumeSwipeSource: (any VolumeSwipeProviding)?
    private let diagnostics: TapQDiagnosticEmitter
    private var mode: Mode = .idle
    private var eventContinuation: AsyncStream<GestureEvent>.Continuation?
    private var sampleContinuation: AsyncStream<HeadMotionSample>.Continuation?

    /// A session on the real hardware: CoreMotion for head motion, CoreAudio for stem
    /// swipes. Inert inside an XCTest host, where CoreMotion must not be touched — tests
    /// use `init(configuration:motionSource:volumeSwipeSource:diagnostics:)` instead.
    public convenience init(
        configuration: Configuration = .init(),
        diagnostics: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        #if canImport(CoreMotion)
        let motionSource: any HeadphoneMotionSource = HeadphoneMotionManagerSource()
        #else
        let motionSource: any HeadphoneMotionSource = UnavailableMotionSource()
        #endif
        #if os(macOS)
        let volumeSwipeSource: (any VolumeSwipeProviding)? =
            VolumeSwipeDetector(diagnosticSink: diagnostics)
        #else
        let volumeSwipeSource: (any VolumeSwipeProviding)? = nil
        #endif
        self.init(
            configuration: configuration,
            motionSource: motionSource,
            volumeSwipeSource: volumeSwipeSource,
            diagnostics: diagnostics
        )
    }

    /// A session on injected sources.
    ///
    /// This is the only initializer usable from an XCTest host: the production CoreMotion
    /// source reports itself unavailable there on purpose, because starting (or even
    /// stopping) real motion updates in an unsigned test process trips a TCC abort on an
    /// AirPods-paired machine. Pass `ScriptedMotionSource` to drive detection from
    /// synthetic samples or a recorded capture, or `UnavailableMotionSource` to exercise
    /// the no-headphones path. `volumeSwipeSource` is nil by default because there is no
    /// hardware-free stand-in for the system volume.
    public init(
        configuration: Configuration = .init(),
        motionSource: any HeadphoneMotionSource,
        volumeSwipeSource: (any VolumeSwipeProviding)? = nil,
        diagnostics: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.configuration = configuration
        self.volumeSwipeSource = volumeSwipeSource
        self.diagnostics = TapQDiagnosticEmitter(category: "GestureSession", sink: diagnostics)
        self.detector = HeadGestureDetector(
            config: configuration.gestures,
            tapConfig: configuration.taps,
            source: motionSource,
            diagnosticSink: diagnostics
        )
        detector.tiltConfig = configuration.tilts
        detector.swipeConfig = configuration.swipes
        detector.tapDetectionEnabled = configuration.tapDetectionEnabled
        detector.swipeDetectionEnabled = configuration.motionSwipeDetectionEnabled
    }

    // MARK: - Curated tier

    /// Starts detection and delivers every event to `onEvent` on the main actor.
    ///
    /// Calling this while `motionSamples()` is streaming records a diagnostic and does
    /// nothing — see the mutual-exclusion note on the type.
    public func start(onEvent: @escaping @MainActor (GestureEvent) -> Void) {
        guard mode != .raw else {
            diagnostics.record(
                "curated.unavailable",
                level: .warning,
                fields: ["reason": "raw_capture_active"]
            )
            return
        }
        // Assign the callback-style channels before `start` opens the subscription so a
        // first sample cannot arrive against a half-wired session.
        detector.onMotionSwipe = { onEvent(.motionSwipe($0)) }
        detector.onMotionLost = { onEvent(.motionLost($0)) }
        detector.onMotionRestored = { onEvent(.motionRestored) }
        // Three starts, one subscription: the detector installs each handler and only the
        // first opens the motion stream.
        detector.start(onGesture: { onEvent(.headGesture($0)) })
        detector.start(onTap: { onEvent(.tap($0)) })
        detector.start(onTilt: { onEvent(.tilt($0)) })
        if configuration.volumeSwipesEnabled, let volumeSwipeSource {
            volumeSwipeSource.start(onSwipe: { onEvent(.volumeSwipe($0)) })
        }
        mode = .curated
    }

    /// Starts detection and delivers events as an `AsyncStream`.
    ///
    /// Single subscriber: one session drives one stream. A second call replaces the
    /// callback the detectors hold, so the earlier stream stops receiving events — that is
    /// a wiring mistake rather than something this type polices. Ending consumption (task
    /// cancellation, `break`, or dropping the stream) stops the session.
    ///
    /// If `motionSamples()` is streaming, this finishes immediately for the same reason
    /// that call does in reverse.
    public func events() -> AsyncStream<GestureEvent> {
        let (stream, continuation) = AsyncStream<GestureEvent>.makeStream()
        start { continuation.yield($0) }
        guard mode == .curated else {
            // `start` declined (raw capture is active and recorded the diagnostic). Finish
            // rather than hand back a stream that would await events forever.
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            // `onTermination` runs on whatever context finished the stream — including a
            // cancelled consumer task. Hop back before touching main-actor detector state.
            Task { @MainActor in self?.stop() }
        }
        eventContinuation = continuation
        return stream
    }

    // MARK: - Raw tier

    /// Streams complete motion samples without classifying them — the input to a capture
    /// study, a replay recording, or a calibration run (see `CalibrationService`).
    ///
    /// Mutually exclusive with the curated tier: if `start(onEvent:)` or `events()` is
    /// active, or if headphone motion is unavailable, this records a diagnostic and
    /// returns a stream that finishes immediately rather than trapping. Ending consumption
    /// stops the session.
    public func motionSamples() -> AsyncStream<HeadMotionSample> {
        guard mode != .curated else {
            diagnostics.record(
                "raw.unavailable",
                level: .warning,
                fields: ["reason": "curated_detection_active"]
            )
            return AsyncStream { $0.finish() }
        }
        let (stream, continuation) = AsyncStream<HeadMotionSample>.makeStream()
        let started = detector.startCapture { (sample: HeadMotionSample) in
            continuation.yield(sample)
        }
        guard started else {
            diagnostics.record(
                "raw.unavailable",
                level: .warning,
                fields: ["reason": "headphone_motion_unavailable"]
            )
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        sampleContinuation = continuation
        mode = .raw
        return stream
    }

    // MARK: - Lifecycle

    /// Stops whichever tier is running, releases the motion subscription, and finishes any
    /// stream this session handed out. Idempotent.
    public func stop() {
        switch mode {
        case .idle:
            break
        case .curated:
            detector.stop()
        case .raw:
            detector.stopCapture()
        }
        volumeSwipeSource?.stop()
        mode = .idle
        // Finish after the detectors are down so a consumer cannot observe the stream end
        // while samples are still being delivered.
        eventContinuation?.finish()
        eventContinuation = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
    }

    /// Attaches a TapQ-1 encoder backend to the head-motion channel. `.shadow` records the
    /// encoder's detections as diagnostics while the heuristics keep driving events;
    /// `.primary` swaps them, with the heuristics still running as the comparison shadow
    /// and the automatic fallback. Passes straight through to `HeadGestureDetector`.
    public func configureEncoder(
        scorer: any MotionWindowScoring,
        config: EncoderConfig = .init(),
        mode: EncoderMode
    ) {
        detector.configureEncoder(scorer: scorer, config: config, mode: mode)
    }
}
