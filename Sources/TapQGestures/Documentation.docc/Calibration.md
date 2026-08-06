# Calibration

Tune the detection thresholds to one wearer, and decide where the profile is stored.

## Overview

How large a nod is varies by person, by how the earbuds sit, and by whether someone is
sitting at a desk or walking. The default thresholds are a compromise that works for most
people; calibration replaces the amplitude thresholds with values derived from that
wearer's own motion, which is the difference between a gesture that fires reliably and one
that needs three attempts.

Calibration is optional. An uncalibrated session runs on the defaults and reports events
normally.

### Collect the phases

Calibration input is a few seconds of motion per phase, labeled by what the wearer was
actually doing: sitting still, nodding, shaking, tapping. Collect the samples from the raw
tier.

```swift
@MainActor
func collect(_ session: GestureSession, seconds: TimeInterval) async -> [HeadMotionSample] {
    var collected: [HeadMotionSample] = []
    let deadline = Date().addingTimeInterval(seconds)
    for await sample in session.motionSamples() {
        collected.append(sample)
        if Date() >= deadline { break }
    }
    return collected
}
```

Breaking out of the stream stops the session, so each phase above is its own capture — put
your instructions to the wearer ("now nod a few times") between the calls.

### Derive and store the profiles

``CalibrationService`` turns one capture into saved profiles. It adds no threshold math of
its own: the values come from `GestureCalibrator` and `TapCalibrator` in the raw tier, and
the quality gates are theirs.

```swift
let samples = GestureCalibrationSamples(
    resting: resting, nod: nod, shake: shake, tap: tap
)
let service = CalibrationService(store: CalibrationStore.defaultStore())
do {
    try service.calibrateGestures(from: samples)
    try service.calibrateTap(from: samples)
} catch let error as CalibrationServiceError {
    // The message reports what was measured and what it had to clear.
    print(error.localizedDescription)
}
```

The `GestureCalibrationSamples(resting:nod:shake:tap:)` initializer does the phase-to-axis
reduction for you — pitch from the nod, yaw from the shake, acceleration magnitude from
rest and tap.

Rejection is the point of the gates. A profile derived from a weak or ambiguous capture
would pull the detection threshold down toward the wearer's own resting jitter, and every
gesture after that would be guesswork. ``CalibrationServiceError`` carries the measured
peaks and the floor they had to clear, so you can tell the wearer what was actually seen
instead of "try again". Nothing is written when a capture is rejected, and the two profiles
are independent: a failed tap calibration can never discard a valid nod/shake one.

### Apply the profiles

```swift
let store = CalibrationStore.defaultStore()
let session = GestureSession(configuration: .calibrated(from: store))
```

`.calibrated(from:)` overlays whatever the store holds onto the defaults. Absent,
unreadable, and schema-rejected profiles are all treated as "not calibrated" and leave that
half of the configuration at its defaults, so a corrupt tap profile cannot cost you working
nod/shake detection. That fallback is silent by design. Call `store.exists(.gesture)`
yourself if you want to tell the wearer they are running uncalibrated.

### Where profiles live

`CalibrationStore.defaultStore()` writes two JSON documents, mode `0600`, to
`~/Library/Application Support/TapQ/` — `gesture-calibration.json` and
`tap-calibration.json` — or to `$TAPQ_CONFIG_DIR` when that variable is set. A sandboxed
app gets the container-relative equivalent of that path. Both files are shared with the
`tapq` CLI, so a wearer who has already calibrated there is calibrated here.

To store them somewhere else — a Keychain item, a synced container, a database, or memory
during a test — implement `CalibrationProfileStoring` and pass your conformance wherever a
store is accepted. Both ``CalibrationService`` and
``GestureSession/Configuration/calibrated(from:)`` take the protocol, not the concrete
type.

## See Also

- <doc:RawMotion>
- <doc:Testing>
