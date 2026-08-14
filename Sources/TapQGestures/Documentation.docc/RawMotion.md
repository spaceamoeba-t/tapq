# Raw motion

Read unclassified samples, and run the detection pipeline on your own terms.

## Overview

The raw tier exists because the curated vocabulary is a product decision, not a limit of
the hardware. Below ``GestureEvent`` sit complete motion samples and a deterministic,
hardware-free pipeline, both public and both supported. Use them to build a different
vocabulary, to record a capture study, or to replace TapQ's classification entirely while
keeping its motion plumbing.

### Samples

`GestureSession.motionSamples()` streams `HeadMotionSample` without classifying it. Each
sample carries:

| Field | Meaning |
|---|---|
| `timestamp` | Device motion timestamp, in seconds |
| `pitch`, `yaw`, `roll` | Attitude in radians; roll is the lateral ear-toward-shoulder axis |
| `userAcceleration` | Signed 3-axis acceleration with gravity removed, in g |
| `rotationRate` | Signed 3-axis rotation rate, in rad/s |
| `gravity` | Gravity direction in the earbud frame — the reference for "up" regardless of ear fit |
| `accelerationMagnitude`, `rotationMagnitude` | Derived magnitudes, authoritative for the magnitude-based analyzers |

Samples arrive at roughly 25 Hz on the devices this has been measured on. Treat that as an
observation, not a contract: the rate is CoreMotion's and the device's, it is not
configurable, and it can differ by hardware and by system conditions. Anything you build on
top should read `timestamp` rather than count samples. `hasPerAxisData` reports whether the
producing adapter supplied signed per-axis values; a sample recorded before per-axis
capture existed leaves the vectors at `.zero`, and direction-aware analysis must skip it
rather than read zeros as stillness.

The curated and raw tiers are mutually exclusive within one session. Capturing while
detecting means two sessions on two sources.

### Observe samples during curated detection

``MotionSampleObserving`` is the way past that exclusivity when what you want is not a
second stream but a second *consumer* of the one the detector already owns. Attach an
observer to ``HeadGestureDetector`` and it receives every sample the gesture pipeline
ingests, after recovery handling and before dispatch, plus a `streamInterrupted()` call on
teardown, session reset, and confirmed motion loss.

```swift
@MainActor
final class PostureMonitor: MotionSampleObserving {
    func ingest(_ sample: HeadMotionSample) { /* your own pure analyzer */ }
    func streamInterrupted() { /* drop the window; it must not span a gap */ }
}

let detector = HeadGestureDetector(source: motionSource)
detector.setMotionSampleObserver(monitor)   // held weakly; pass nil to detach
```

One subscription, several pure consumers, none sharing window state — the same shape TapQ's
own wearer-speech detection uses. An observer must not block: it runs on the main actor
inside the sample path, so anything expensive belongs behind a queue of your own.

### Drive the pipeline yourself

`MotionGesturePipeline` is the whole classifier: sliding windows, debounce, the
double-gesture pairing, and the tilt and swipe channels. It is a plain value type with no
CoreMotion dependency, so it runs on live samples, on a recorded capture, or in a unit
test, and it produces the same output for the same input every time.

```swift
@MainActor
func drivePipelineYourself(_ session: GestureSession) async {
    var pipeline = MotionGesturePipeline(
        config: HeadGestureConfig(amplitudeThreshold: 0.35),
        tapConfig: TapConfig(),
        tiltConfig: TiltConfig(),
        swipeConfig: SwipeConfig()
    )
    for await sample in session.motionSamples() {
        let result = pipeline.ingest(sample)
        switch result.gesture {
        case .nod: approve()
        case .shake: deny()
        case nil: break
        }
        if result.tap != nil { approve() }
    }
}
```

`ingest(_:)` returns a `MotionDetectionResult` with the gesture, tap, tilt, and swipe
detected on that sample, any of which may be nil. `reset()` clears the temporal state
without disturbing the configuration — call it across a stream gap so a window never spans
a disconnect.

The individual analyzers are public too: `GestureAnalyzer`, `TapAnalyzer`, `TiltAnalyzer`,
`SwipeAnalyzer`, and `VolumeSwipeAnalyzer`. Each takes its own config struct
(`HeadGestureConfig`, `TapConfig`, `TiltConfig`, `SwipeConfig`) whose fields document the
physical quantity they threshold, and each is a pure function over arrays of values. If you
only want to change *how* a gesture is judged, replace one analyzer rather than the tier.

The motion-swipe channel is experimental and off by default. It stays off until a capture
study confirms that swipe direction is separable at the sample rate the hardware actually
delivers.

### Attach an encoder

`GestureSession.configureEncoder(scorer:config:mode:)` puts a learned model in the head
motion path. ``CoreMLMotionScorer`` is the Core ML backend; any conformance to
`MotionWindowScoring` works.

```swift
let scorer = try await CoreMLMotionScorer.load(modelURL: modelURL)
session.configureEncoder(scorer: scorer, config: EncoderConfig(), mode: .shadow)
```

Two modes matter. `.shadow` runs the model on every window and records its detections as
diagnostics while the heuristics keep driving events — comparison on live motion at zero
behavior risk. `.primary` swaps them: the model drives events, the heuristics keep running
as the comparison shadow and remain the automatic fallback when no model loads.

A model must declare the feature contract it was trained against. `CoreMLMotionScorer`
reads the layout version (`tapq1-features-v1`), the class list, and the window length from
the model's metadata and refuses to load anything that disagrees with this runtime, so a
stale model fails at load rather than scoring nonsense. `EncoderFeatureLayout` holds the
runtime's side of that contract: nine per-sample channels (signed acceleration, rotation
rate, and gravity — attitude is deliberately absent because yaw drifts with body heading),
fixed normalization scales, and a 32-sample window.

## See Also

- <doc:Calibration>
- <doc:Testing>
