# Testing without hardware

Drive the real detection pipeline from synthetic samples, in a process that must never
touch CoreMotion.

## Overview

Real headphone motion is unreachable from a unit test, and not by omission. Starting — or
even stopping — CoreMotion updates inside an unsigned XCTest host trips a TCC motion
permission abort on a machine with AirPods paired, killing the test process rather than
failing a test. The SDK treats that as a hard constraint: the production motion source
reports `isDeviceMotionAvailable == false` whenever `XCTestCase` is linked into the
process, and never calls into CoreMotion at all.

Two consequences follow. ``GestureCapabilities/current()`` reports `headphoneMotion` as
false under XCTest, on any machine. And `GestureSession(configuration:diagnostics:)` — the
convenience initializer that builds the real sources — is inert there. Tests use the
injecting initializer instead.

### Send samples yourself

``ScriptedMotionSource`` is a `HeadphoneMotionSource` you drive directly. Detection runs
end to end against it: the same analyzers, the same pairing windows, the same motion-loss
lifecycle.

```swift
@MainActor
func testDoubleNodIsReported() {
    let source = ScriptedMotionSource()
    let session = GestureSession(motionSource: source)
    var events: [GestureEvent] = []
    session.start { events.append($0) }

    for sample in Self.doubleNod {
        source.send(sample)
    }

    XCTAssertEqual(events, [.headGesture(.nod)])
}
```

Because the pipeline is time-windowed, the sample timestamps are the test fixture: a
"double nod" is two pitch excursions separated by more than `minDoubleNodGap` and less than
`doubleNodWindowSeconds`, and moving those timestamps is how you test the pairing rules.
Sending before `startUpdates` or after `stopUpdates` is a no-op, matching the real source.

`fail(_:)` delivers a stream fault. The detector treats it as an interruption rather than
an outage, so a single failure does not immediately produce `.motionLost` — the grace
period has to expire first, which is itself worth a test.

### Replay a capture

`play(_:rate:)` replays recorded samples at the pace their own timestamps describe, so a
capture that stuttered replays with its stutter. It suspends until the last sample is sent,
and cancelling the surrounding task stops it. `rate` scales playback: `8.0` replays eight
times as fast, which keeps a long capture usable in a test suite.

```swift
await source.play(recordedSamples, rate: 8.0)
```

The same call is how you compare backends or configurations offline against a fixed input.

### Exercise the no-headphones path

``UnavailableMotionSource`` reports motion as unavailable and delivers nothing. Use it to
test what your app shows when a wearer has no compatible device connected.

```swift
let session = GestureSession(motionSource: UnavailableMotionSource())
```

### Keep calibration out of the file system

`CalibrationService` and `GestureSession.Configuration.calibrated(from:)` both accept
`CalibrationProfileStoring`, so a test can substitute an in-memory conformance and leave
the developer's real profiles alone.

```swift
final class InMemoryCalibrationStore: CalibrationProfileStoring, @unchecked Sendable {
    struct NotStored: Error {}

    private var gesture: TapQGestureCalibrationProfile?
    private var tap: TapQTapCalibrationProfile?

    func loadGesture() throws -> TapQGestureCalibrationProfile {
        guard let gesture else { throw NotStored() }
        return gesture
    }

    func save(_ profile: TapQGestureCalibrationProfile) throws { gesture = profile }

    // ...plus loadTap, save(_: TapQTapCalibrationProfile), exists(_:), and reset(_:).
}
```

A conformance that fails its loads while still answering `exists(_:)` with `true` is the
shape of a corrupt profile on disk, and is the case worth testing: the configuration must
fall back to defaults rather than propagate the failure.

### Diagnostics as assertions

Every declined or rejected path records a diagnostic rather than trapping — a curated call
while raw capture is active, a rejected echo, an expired pairing window. Pass a
`TapQDiagnosticSink` that collects events as the session's `diagnostics:` argument, and
assert on what was recorded when the observable output is, correctly, nothing.

## See Also

- <doc:RawMotion>
- <doc:Calibration>
