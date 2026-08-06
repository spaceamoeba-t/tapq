/// `import TapQGestures` is the whole SDK.
///
/// The three re-exported modules are not an implementation detail leaking through — they
/// *are* the raw tier of the SDK's two-tier surface. `GestureSession` and `GestureEvent`
/// are the curated tier: one enum of doubled, false-positive-resistant commands. Under it
/// sit the pieces an embedder reaches for when the curated tier is too coarse:
///
/// - `TapQGestureContracts` — the gesture vocabulary (`HeadGesture`, `TapCommand`,
///   `TiltCommand`, the swipe commands), the provider protocols, and the diagnostic sink.
/// - `TapQDetectionBaseline` — `MotionGesturePipeline` and the individual analyzers,
///   every tuning config, the calibrators, `HeadMotionSample`, and the TapQ-1 encoder
///   contracts. All hardware-free and unit-testable.
/// - `TapQCalibrationStore` — `CalibrationStore` and the `CalibrationProfileStoring`
///   protocol an app implements to keep profiles somewhere other than on disk.
///
/// Both tiers are supported: run `MotionGesturePipeline` yourself against your own sample
/// source and never touch `GestureSession`, or take the session and ignore the rest.
@_exported import TapQGestureContracts
@_exported import TapQDetectionBaseline
@_exported import TapQCalibrationStore
