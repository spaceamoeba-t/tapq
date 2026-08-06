# TapQ SDK integration guide

How to embed `TapQGestures` — TapQ's gesture engine — in your own macOS app: what
it does, what it needs from you, and what it deliberately leaves out. For the API
reference, build the DocC catalog in
[`Sources/TapQGestures/Documentation.docc`](../Sources/TapQGestures/Documentation.docc)
with `xcodebuild docbuild -scheme TapQGestures`. For a working app, see
[`Examples/GestureBar`](../Examples/GestureBar).

## Overview

`import TapQGestures` gives you two tiers over the same motion stream.

The **curated tier** is `GestureSession` and `GestureEvent`: one enum of commands
already filtered for false positives. Every command is doubled — a single nod,
shake, tilt, or tap never fires — because these events exist to approve or reject a
proposed action, where a false positive costs more than a missed detection. The
pairing windows and amplitude thresholds are configurable; the doubling is
structural.

The **raw tier** is `HeadMotionSample` and `MotionGesturePipeline`: complete motion
samples delivered unclassified, and a hardware-free, deterministic pipeline you can
drive with your own thresholds, your own analyzers, or recorded data. Both tiers
are supported; neither is a fallback for the other. One session runs one tier at a
time.

What the SDK does not contain is as deliberate as what it does. There is no agent
integration, no broker, no wire protocol, no approval or question model, no voice
recognition, and no audio capture of any kind. Those live in the `tapq` runtime and
are not reachable from this package — a boundary check in CI fails the build if
`TapQGestures` ever imports them.

## Requirements

| | |
|---|---|
| Platform | macOS 14 or newer |
| Toolchain | Swift 6 (Xcode 16 or a compatible toolchain) |
| Hardware | A device that exposes headphone motion through CoreMotion |

## Install

```swift
.package(url: "https://github.com/spaceamoeba-t/tapq.git", from: "0.5.0")
```

Then add the product to the target that uses it:

```swift
.product(name: "TapQGestures", package: "tapq")
```

In Xcode, use **File > Add Package Dependencies** with the same URL and select the
`TapQGestures` library. The package re-exports the three portable modules the SDK
is built on, so one import is enough for both tiers.

## Permissions

Head motion is the only thing the SDK asks the system for. Declare
`NSMotionUsageDescription` in the `Info.plist` of the app that links it:

```xml
<key>NSMotionUsageDescription</key>
<string>Reads headphone motion to detect nods, shakes, and taps.</string>
```

macOS shows that string on the first CoreMotion call. A process that reaches
CoreMotion without the key is terminated rather than prompted, which reads as a
crash on first gesture.

### Bundle identity

TCC records its decision against a code-signed bundle identity. A bare SwiftPM
executable — `swift run`, or the binary under `.build/` — has no stable one, so the
grant either cannot be recorded or is attached to something that changes on the next
build. The result is a process that is denied motion, or re-prompted, with no error
you can catch.

Anything that needs real headphone motion therefore has to run from a signed `.app`
bundle: an `Info.plist` at `Contents/Info.plist` with the usage description and a
stable `CFBundleIdentifier`, the executable in `Contents/MacOS/`, and a code
signature over the bundle (ad-hoc is enough for local development). A normal Xcode
app target already produces that shape.
[`Examples/GestureBar/scripts/package-example-app.sh`](../Examples/GestureBar/scripts/package-example-app.sh)
is the same assembly for a SwiftPM executable, in about thirty lines.

The prompt appears once per identity. `tccutil reset Motion <bundle-id>` clears the
recorded decision so you can see it again during development.

### Explicitly not required

- **Microphone.** No audio capture; `NSMicrophoneUsageDescription` is not needed and
  should not be added.
- **Speech recognition.** No `NSSpeechRecognitionUsageDescription`. Voice command
  matching lives in the `tapq` runtime.
- **Audio-input entitlement.** `com.apple.security.device.audio-input` is not needed,
  sandboxed or not.
- **Network.** Detection is entirely local; the SDK opens no connections.

Stem swipes are the case that surprises people: the SDK infers them from changes in
the system output volume through a CoreAudio property listener, which reads a
system-wide value and needs no permission and no entitlement.

## Quick start

```swift
import TapQGestures

@MainActor
func startGestures() -> GestureSession {
    let session = GestureSession(
        configuration: .calibrated(from: CalibrationStore.defaultStore())
    )
    session.start { event in
        switch event {
        case .headGesture(.nod): approve()
        case .headGesture(.shake): deny()
        case .volumeSwipe(let direction): moveSelection(direction)
        case .motionLost(.neverStreamed): showConnectHeadphonesPrompt()
        case .motionLost: showReconnectHint()
        // `GestureEvent` is not frozen: taps, tilts, and later cases arrive here.
        default: break
        }
    }
    return session // Detection stops when the session is released.
}
```

`.motionLost` carries a `MotionLossReason`: `.neverStreamed` means no compatible
headphones were ever there, while `.lostWhileStreaming` and `.silentStream` describe a
stream that existed and stopped. They deserve different words — telling someone with no
AirPods to reconnect is not help.

`GestureSession` is `@MainActor`; events are delivered there. `events()` provides
the same events as an `AsyncStream` when you would rather `for await` than install a
callback. Read `GestureCapabilities.current()` before offering a gesture in your UI:
on a Mac with no compatible headphones paired there is no head motion at all, and an
app waiting for a nod that can never arrive is indistinguishable from a broken one.

## Calibration

How large a nod is varies by person and by how the earbuds sit. Calibration replaces
the amplitude thresholds with values derived from one wearer's own motion. It is
optional — an uncalibrated session runs on defaults.

Collect a few seconds of samples per phase (resting, nod, shake, tap) from
`session.motionSamples()`, hand them to `CalibrationService`, and apply the result
with `Configuration.calibrated(from:)`. The service adds no threshold math of its
own and refuses to save a capture that cannot be separated from the wearer's resting
jitter, reporting the measured peaks so you can tell the wearer what was actually
seen. Profiles are stored as two independent JSON documents in
`~/Library/Application Support/TapQ/`, shared with the `tapq` CLI; implement
`CalibrationProfileStoring` to put them somewhere else. Absent, unreadable, and
schema-rejected profiles all fall back to defaults silently, so call
`store.exists(.gesture)` yourself if you want to tell the wearer they are running
uncalibrated.

Full walkthrough: the `Calibration` article in the DocC catalog.

## Testing

Real headphone motion is unreachable from a unit test, and not by omission: starting
or stopping CoreMotion updates inside an unsigned XCTest host trips a TCC motion
abort that kills the process rather than failing a test. The SDK's production motion
source reports itself unavailable whenever `XCTestCase` is linked into the process
and never calls into CoreMotion.

Tests use the injecting initializer instead. `ScriptedMotionSource` drives the real
pipeline from samples you send — `send(_:)` for synthetic fixtures, `fail(_:)` for a
stream fault, `play(_:rate:)` to replay a recorded capture at its own pace.
`UnavailableMotionSource` exercises the no-headphones path, and an in-memory
`CalibrationProfileStoring` keeps a test off the developer's real profiles. Because
the pipeline is time-windowed, sample timestamps are the fixture: that is how you
test the pairing rules.

Full walkthrough: the `Testing without hardware` article in the DocC catalog.

## Device compatibility

| | |
|---|---|
| Head gestures, taps, tilts | Any device that reports motion through `CMHeadphoneMotionManager` — AirPods Pro (any generation), AirPods 3 and later, AirPods Max, and several Beats models |
| Stem swipes | Devices whose stem controls change the system output volume (AirPods Pro 2 and later) |
| Tested | AirPods Pro — the maintainer's hardware |

That table is a compatibility claim, not a test matrix. Apple does not publish the
list of models that expose headphone motion, and TapQ has been exercised on one of
them. Reports from other hardware are welcome.

Stem swipes are inferred from output-volume changes, so they need hardware that
produces those changes; on a device without stem volume control, no `.volumeSwipe`
event is ever emitted and the rest of the vocabulary is unaffected.

## Versioning and stability

The SDK is pre-1.0 and follows the repository's version. Expect corrections before
the first stable release, and pin a version rather than tracking a branch.

- **Enums are not frozen.** New device families and input channels arrive as new
  cases in minor releases, and that is not treated as a breaking change. Switch over
  `GestureEvent` with a `default` (or `@unknown default`) clause. Adding an
  exhaustive switch with no default is the one thing guaranteed to break on upgrade.
- **Capability and config structs gain fields.** Read the `GestureCapabilities`
  properties you need rather than pattern-matching the whole value.
- **The sample rate is not a contract.** Samples arrive at roughly 25 Hz on the
  hardware this has been measured on. The rate belongs to CoreMotion and the device,
  is not configurable, and can differ by model and by system conditions — read
  `HeadMotionSample.timestamp` rather than counting samples.
- **The motion-swipe channel is experimental** and off by default, pending a capture
  study that confirms direction separability at the rate the hardware delivers.
- **Calibration profiles are versioned.** A profile written by a schema the running
  version does not support is rejected and treated as absent rather than
  reinterpreted.

## Where this is going

The vocabulary is typed per body placement rather than flattened into one generic
gesture enum: head motion is what exists today, and a wrist or ring vocabulary would
be its own enum with its own physical meaning, under the same session, capability,
and calibration framework. A binding layer that maps vocabularies onto app-defined
actions is planned above them, so an app can express "approve" once and let the
framework decide which placement satisfies it. The tiers below that layer are not
expected to change shape.

## iOS

Not shipped. iOS is on the [roadmap](ROADMAP.md), and the code is structured for it
— the detection pipeline, calibrators, and gesture vocabulary are portable and carry
no Apple framework imports, and CoreMotion's headphone motion API is the same one
iOS exposes. What is not there yet is an iOS entry in the package's platform list, a
build, or any testing, and the volume-swipe channel has no iOS equivalent: the
CoreAudio property listener it depends on is macOS-only. Treat iOS as planned work,
not an undocumented capability.
