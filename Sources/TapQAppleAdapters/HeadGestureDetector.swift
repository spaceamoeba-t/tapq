import Foundation
import TapQContracts
import TapQDetectionBaseline

/// Adapts the Apple headphone motion source to the portable `MotionGesturePipeline`.
/// One subscription feeds gestures, taps, and tilts so competing CoreMotion managers
/// never contend for the same headphones.
@MainActor public final class HeadGestureDetector: NSObject, HeadGestureProviding,
    TapCommandProviding, TiltCommandProviding {

    public var config: HeadGestureConfig {
        get { pipeline.config }
        set { pipeline.config = newValue }
    }

    public var tapConfig: TapConfig {
        get { pipeline.tapConfig }
        set { pipeline.tapConfig = newValue }
    }

    public var tapDetectionEnabled: Bool {
        get { pipeline.tapDetectionEnabled }
        set { pipeline.tapDetectionEnabled = newValue }
    }

    public var tiltConfig: TiltConfig {
        get { pipeline.tiltConfig }
        set { pipeline.tiltConfig = newValue }
    }

    public var swipeConfig: SwipeConfig {
        get { pipeline.swipeConfig }
        set { pipeline.swipeConfig = newValue }
    }

    /// Experimental; see `MotionGesturePipeline.swipeDetectionEnabled`.
    public var swipeDetectionEnabled: Bool {
        get { pipeline.swipeDetectionEnabled }
        set { pipeline.swipeDetectionEnabled = newValue }
    }

    /// Experimental motion-swipe events; delivered only while swipe detection is enabled.
    public var onMotionSwipe: (@MainActor (MotionSwipeCommand) -> Void)?

    /// Fired once per contiguous motion outage. A later valid sample rearms the callback
    /// so a genuinely new outage is reported as well.
    public var onMotionLost: (@MainActor () -> Void)?

    /// How a configured TapQ-1 encoder backend participates. `.off` until
    /// `configureEncoder` succeeds; the heuristic pipeline always keeps running so a
    /// backend failure can never leave the detector silent.
    public private(set) var encoderMode: EncoderMode = .off

    private var pipeline: MotionGesturePipeline
    private var encoderPipeline: EncoderMotionPipeline?
    private var onGesture: (@MainActor (HeadGesture) -> Void)?
    private var onTap: (@MainActor (TapCommand) -> Void)?
    private var onTilt: (@MainActor (TiltCommand) -> Void)?
    private var onSample: (@MainActor (HeadMotionSample) -> Void)?
    private var running = false
    private var capturing = false
    private var motionUpdatesActive = false
    private var motionLossSignaled = false
    /// Availability polling, an interruption grace period, and first-sample startup
    /// recovery have independent lifecycles. Sharing one task slot lets one concern
    /// accidentally cancel another and was the source of hard-to-explain silent states.
    private var availabilityTask: Task<Void, Never>?
    private var motionInterruptionTask: Task<Void, Never>?
    private var firstSampleWatchdogTask: Task<Void, Never>?
    /// Changes for every source subscription and teardown. Callback closures capture the
    /// epoch so a late sample from an earlier approval window cannot enter the new one.
    private var subscriptionEpoch: UInt64 = 0
    private var awaitingFirstSampleEpoch: UInt64?
    private var firstSampleStartedAt: TimeInterval?
    private let motionLossGraceNanoseconds: UInt64
    private let availabilityRetryNanoseconds: UInt64
    private let firstSampleTimeoutNanoseconds: UInt64
    private let startupRestartBackoffNanoseconds: UInt64
    private let maximumStartupRestarts: Int
    private let source: HeadphoneMotionSource
    private let diagnostics: TapQDiagnosticEmitter
    private let diagnosticSink: any TapQDiagnosticSink

    /// Test seam: inject a fake source so tests can exercise adapter lifecycle without
    /// touching CoreMotion.
    init(config: HeadGestureConfig = .init(), tapConfig: TapConfig = .init(),
         source: HeadphoneMotionSource,
         motionLossGrace: TimeInterval = 1.5,
         availabilityRetry: TimeInterval = 0.25,
         firstSampleTimeout: TimeInterval = 1.0,
         startupRestartBackoff: TimeInterval = 0.2,
         maximumStartupRestarts: Int = 1,
         diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.pipeline = MotionGesturePipeline(
            config: config, tapConfig: tapConfig, diagnosticSink: diagnosticSink)
        self.source = source
        self.motionLossGraceNanoseconds = UInt64(max(0, motionLossGrace) * 1_000_000_000)
        self.availabilityRetryNanoseconds = UInt64(max(0.01, availabilityRetry) * 1_000_000_000)
        self.firstSampleTimeoutNanoseconds = UInt64(
            max(0.01, firstSampleTimeout) * 1_000_000_000)
        self.startupRestartBackoffNanoseconds = UInt64(
            max(0, startupRestartBackoff) * 1_000_000_000)
        self.maximumStartupRestarts = max(0, maximumStartupRestarts)
        self.diagnostics = TapQDiagnosticEmitter(category: "GestureAdapter", sink: diagnosticSink)
        self.diagnosticSink = diagnosticSink
        super.init()
    }

    /// Attaches a TapQ-1 encoder backend. In `.shadow` mode the encoder's detections
    /// are recorded as diagnostics while heuristics keep driving events; in `.primary`
    /// mode the encoder drives events and heuristic detections are recorded for
    /// comparison. Passing `.off` detaches the backend.
    public func configureEncoder(
        scorer: any MotionWindowScoring,
        config: EncoderConfig = .init(),
        mode: EncoderMode
    ) {
        encoderMode = mode
        encoderPipeline = mode == .off ? nil : EncoderMotionPipeline(
            scorer: scorer, config: config, diagnosticSink: diagnosticSink)
        diagnostics.record("encoder.configured", fields: ["mode": mode.rawValue])
    }

    public convenience init(config: HeadGestureConfig = .init(),
                            tapConfig: TapConfig = .init(),
                            diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        #if canImport(CoreMotion)
        self.init(config: config, tapConfig: tapConfig,
                  source: HeadphoneMotionManagerSource(), diagnosticSink: diagnosticSink)
        #else
        self.init(config: config, tapConfig: tapConfig,
                  source: UnavailableMotionSource(), diagnosticSink: diagnosticSink)
        #endif
    }

    public static var isAvailable: Bool {
        #if canImport(CoreMotion)
        return HeadphoneMotionManagerSource().isDeviceMotionAvailable
        #else
        return false
        #endif
    }

    public func start(onGesture: @escaping @MainActor (HeadGesture) -> Void) {
        self.onGesture = onGesture
        startDetecting()
    }

    public func start(onTap: @escaping @MainActor (TapCommand) -> Void) {
        self.onTap = onTap
        startDetecting()
    }

    public func start(onTilt: @escaping @MainActor (TiltCommand) -> Void) {
        self.onTilt = onTilt
        startDetecting()
    }

    func setGestureHandlerForTesting(
        _ handler: @escaping @MainActor (HeadGesture) -> Void
    ) {
        onGesture = handler
    }

    func handleMotionLoss(error: Error? = nil) {
        confirmMotionLoss(errorDescription: error.map { String(describing: $0) })
    }

    /// A single CoreMotion disconnect/nil callback is not final. AirPods can briefly
    /// cycle their motion connection while their audio connection remains healthy.
    /// Keep the current interaction open during a short grace period; any valid sample
    /// cancels this task and proves recovery.
    private func handleMotionInterruption(error: Error? = nil) {
        guard running, !motionLossSignaled else { return }
        let description = error.map { String(describing: $0) }
        if motionInterruptionTask == nil {
            diagnostics.record(
                "motion.interrupted",
                level: .warning,
                fields: description.map { ["error": $0] } ?? [:]
            )
        }
        guard motionInterruptionTask == nil else { return }
        motionInterruptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.motionLossGraceNanoseconds)
            guard !Task.isCancelled, self.running else { return }
            self.motionInterruptionTask = nil
            self.confirmMotionLoss(errorDescription: description)
        }
    }

    func beginListeningForTesting() {
        resetSession()
        running = true
    }

    func beginCaptureForTesting() {
        resetSession()
        running = true
        capturing = true
    }

    private func startDetecting() {
        guard !running else {
            diagnostics.record("detection.start_skipped", fields: ["running": "\(running)"])
            return
        }
        resetSession()
        running = true
        guard source.isDeviceMotionAvailable else {
            diagnostics.record("motion.waiting_for_device", level: .warning)
            waitForMotionAvailability()
            return
        }
        beginMotionUpdates(attempt: 1)
    }

    private func beginMotionUpdates(attempt: Int) {
        guard running, !motionUpdatesActive else { return }
        // Availability is inherently racy: the caller (or the availability poller) may
        // observe `true`, then lose the headphones before this actual start check. Do
        // not leave the interaction running without either a subscription or a poller.
        guard source.isDeviceMotionAvailable else {
            confirmMotionLoss(
                errorDescription: "headphone motion became unavailable before startup"
            )
            return
        }

        subscriptionEpoch &+= 1
        let epoch = subscriptionEpoch
        awaitingFirstSampleEpoch = epoch
        firstSampleStartedAt = ProcessInfo.processInfo.systemUptime
        motionUpdatesActive = true
        diagnostics.record(
            "motion.start_requested",
            fields: ["attempt": "\(attempt)", "generation": "\(epoch)"]
        )
        armFirstSampleWatchdog(epoch: epoch, attempt: attempt)

        source.startUpdates { [weak self] sample, error in
            guard let self else { return }
            guard self.running,
                  self.motionUpdatesActive,
                  self.subscriptionEpoch == epoch else { return }
            guard let sample, error == nil else {
                self.handleMotionInterruption(error: error)
                return
            }
            self.acceptFirstSampleIfNeeded(epoch: epoch)
            if self.capturing {
                self.handleMotionRecoveryIfNeeded()
                self.onSample?(sample)
            } else {
                self.ingest(sample)
            }
        }
    }

    /// Streams complete portable samples for capture/calibration without invoking the
    /// baseline classifiers.
    @discardableResult
    public func startCapture(
        onSample: @escaping @MainActor (HeadMotionSample) -> Void
    ) -> Bool {
        guard !running, source.isDeviceMotionAvailable else { return false }
        resetSession()
        self.onSample = onSample
        running = true
        capturing = true
        beginMotionUpdates(attempt: 1)
        return true
    }

    /// Compatibility overload for hosts that only need the three calibration values used
    /// before `HeadMotionSample` became the portable capture record.
    @discardableResult
    public func startCapture(
        onSample: @escaping @MainActor (
            _ pitch: Double, _ yaw: Double, _ accelerationMagnitude: Double
        ) -> Void
    ) -> Bool {
        startCapture { sample in
            onSample(sample.pitch, sample.yaw, sample.accelerationMagnitude)
        }
    }

    public func stop() {
        guard running else { return }
        if capturing {
            diagnostics.record("detection.stopped_capture_continues")
            onGesture = nil
            onTap = nil
            onTilt = nil
            onMotionSwipe = nil
            return
        }
        diagnostics.record("motion.stopped")
        teardown()
    }

    public func stopCapture() {
        guard capturing else { return }
        diagnostics.record("capture.stopped")
        teardown()
    }

    private func teardown() {
        running = false
        capturing = false
        cancelLifecycleTasks()
        subscriptionEpoch &+= 1
        awaitingFirstSampleEpoch = nil
        firstSampleStartedAt = nil
        if motionUpdatesActive { source.stopUpdates() }
        motionUpdatesActive = false
        onGesture = nil
        onTap = nil
        onTilt = nil
        onMotionSwipe = nil
        onSample = nil
        pipeline.reset()
        encoderPipeline?.reset()
    }

    private func resetSession() {
        cancelLifecycleTasks()
        // Invalidate any queued callback before opening another logical session. Normal
        // production paths tear down first; this extra epoch is cheap and also protects
        // the adapter's lifecycle test seams.
        subscriptionEpoch &+= 1
        awaitingFirstSampleEpoch = nil
        firstSampleStartedAt = nil
        pipeline.reset()
        encoderPipeline?.reset()
        motionLossSignaled = false
    }

    private func cancelLifecycleTasks() {
        availabilityTask?.cancel()
        availabilityTask = nil
        motionInterruptionTask?.cancel()
        motionInterruptionTask = nil
        firstSampleWatchdogTask?.cancel()
        firstSampleWatchdogTask = nil
    }

    private func ingest(_ sample: HeadMotionSample) {
        handleMotionRecoveryIfNeeded()
        // Heuristics run in every mode: they are the fallback and, in primary mode,
        // the comparison shadow — the cost is trivial next to a model inference.
        let heuristic = pipeline.ingest(sample)
        let delivered: MotionDetectionResult
        switch encoderMode {
        case .off:
            delivered = heuristic
        case .shadow:
            if let shadow = encoderPipeline?.ingest(sample) {
                recordShadowDetections(shadow, backend: "encoder")
            }
            delivered = heuristic
        case .primary:
            delivered = encoderPipeline?.ingest(sample) ?? heuristic
            recordShadowDetections(heuristic, backend: "heuristic")
        }
        if let gesture = delivered.gesture { onGesture?(gesture) }
        if let tap = delivered.tap { onTap?(tap) }
        if let tilt = delivered.tilt { onTilt?(tilt) }
        if let swipe = delivered.swipe { onMotionSwipe?(swipe) }
    }

    private func recordShadowDetections(_ result: MotionDetectionResult, backend: String) {
        guard result != MotionDetectionResult() else { return }
        var fields = ["backend": backend]
        if let gesture = result.gesture { fields["gesture"] = "\(gesture)" }
        if let tap = result.tap { fields["tap"] = "\(tap)" }
        if let tilt = result.tilt { fields["tilt"] = "\(tilt)" }
        if let swipe = result.swipe { fields["swipe"] = "\(swipe)" }
        diagnostics.record("detection.shadow", fields: fields)
    }

    /// `startUpdates` returning only means CoreMotion accepted the request. A stream is
    /// healthy once its current callback actually delivers a sample. If that never
    /// happens, restart the one shared manager once and then fail through to the host.
    private func armFirstSampleWatchdog(epoch: UInt64, attempt: Int) {
        firstSampleWatchdogTask?.cancel()
        firstSampleWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.firstSampleTimeoutNanoseconds)
            guard !Task.isCancelled,
                  self.running,
                  self.motionUpdatesActive,
                  self.subscriptionEpoch == epoch,
                  self.awaitingFirstSampleEpoch == epoch else { return }

            self.diagnostics.record(
                "motion.start_timeout",
                level: .warning,
                fields: [
                    "attempt": "\(attempt)",
                    "available": "\(self.source.isDeviceMotionAvailable)",
                    "generation": "\(epoch)",
                ]
            )

            guard attempt <= self.maximumStartupRestarts else {
                self.firstSampleWatchdogTask = nil
                self.awaitingFirstSampleEpoch = nil
                self.firstSampleStartedAt = nil
                self.confirmMotionLoss(
                    errorDescription: "headphone motion stream started but produced no samples"
                )
                return
            }

            // Invalidate the old callback before stopping. The source also applies its
            // own generation guard, giving both the CoreMotion and detector boundaries
            // protection from late callbacks.
            self.motionInterruptionTask?.cancel()
            self.motionInterruptionTask = nil
            self.awaitingFirstSampleEpoch = nil
            self.firstSampleStartedAt = nil
            self.subscriptionEpoch &+= 1
            let invalidatedEpoch = self.subscriptionEpoch
            self.motionUpdatesActive = false
            self.source.stopUpdates()

            self.diagnostics.record(
                "motion.restart_requested",
                level: .warning,
                fields: [
                    "backoff_ms": "\(self.startupRestartBackoffNanoseconds / 1_000_000)",
                    "next_attempt": "\(attempt + 1)",
                    "previous_generation": "\(epoch)",
                ]
            )

            try? await Task.sleep(nanoseconds: self.startupRestartBackoffNanoseconds)
            guard !Task.isCancelled,
                  self.running,
                  self.subscriptionEpoch == invalidatedEpoch else { return }
            guard self.source.isDeviceMotionAvailable else {
                self.firstSampleWatchdogTask = nil
                self.confirmMotionLoss(
                    errorDescription: "headphone motion unavailable during startup retry"
                )
                return
            }

            // `beginMotionUpdates` arms the next watchdog. Clear this task first so the
            // new subscription owns the task slot without cancelling an unrelated task.
            self.firstSampleWatchdogTask = nil
            self.beginMotionUpdates(attempt: attempt + 1)
        }
    }

    private func acceptFirstSampleIfNeeded(epoch: UInt64) {
        guard awaitingFirstSampleEpoch == epoch else { return }
        let latency = firstSampleStartedAt.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        }
        awaitingFirstSampleEpoch = nil
        firstSampleStartedAt = nil
        firstSampleWatchdogTask?.cancel()
        firstSampleWatchdogTask = nil
        var fields = ["generation": "\(epoch)"]
        if let latency { fields["latency_ms"] = String(format: "%.1f", latency * 1_000) }
        diagnostics.record("motion.first_sample", fields: fields)
    }

    private func handleMotionRecoveryIfNeeded() {
        let wasInterrupted = motionInterruptionTask != nil || motionLossSignaled
        motionInterruptionTask?.cancel()
        motionInterruptionTask = nil
        motionLossSignaled = false
        if wasInterrupted { diagnostics.record("motion.restored") }
    }

    private func waitForMotionAvailability() {
        let retry = availabilityRetryNanoseconds
        let grace = max(retry, motionLossGraceNanoseconds)
        let attempts = max(1, Int((grace + retry - 1) / retry))
        availabilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<attempts {
                try? await Task.sleep(nanoseconds: retry)
                guard !Task.isCancelled, self.running else { return }
                if self.source.isDeviceMotionAvailable {
                    self.availabilityTask = nil
                    self.beginMotionUpdates(attempt: 1)
                    return
                }
            }
            self.availabilityTask = nil
            self.confirmMotionLoss(errorDescription: "headphone motion unavailable")
        }
    }

    private func confirmMotionLoss(errorDescription: String?) {
        availabilityTask?.cancel()
        availabilityTask = nil
        motionInterruptionTask?.cancel()
        motionInterruptionTask = nil
        firstSampleWatchdogTask?.cancel()
        firstSampleWatchdogTask = nil
        awaitingFirstSampleEpoch = nil
        firstSampleStartedAt = nil
        guard running, !motionLossSignaled else { return }
        motionLossSignaled = true
        diagnostics.record(
            "motion.lost",
            level: .error,
            fields: errorDescription.map { ["error": $0] } ?? [:]
        )
        onMotionLost?()
    }

    // Adapter test seams. Algorithm tests live under TapQDetectionBaselineTests.
    func ingestGesture(pitch: Double, yaw: Double, time: TimeInterval) {
        if let gesture = pipeline.ingestGesture(pitch: pitch, yaw: yaw, time: time) {
            onGesture?(gesture)
        }
    }

    func ingestTap(accel: Double, rot: Double, time: TimeInterval) {
        if let tap = pipeline.ingestTap(acceleration: accel, rotation: rot, time: time) {
            onTap?(tap)
        }
    }

    func ingestTilt(roll: Double, pitch: Double, yaw: Double, time: TimeInterval) {
        if let tilt = pipeline.ingestTilt(roll: roll, pitch: pitch, yaw: yaw, time: time) {
            onTilt?(tilt)
        }
    }
}
