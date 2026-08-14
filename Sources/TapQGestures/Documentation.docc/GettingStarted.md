# Getting started

Add the package, declare the motion permission, and read gesture events.

## Overview

TapQGestures requires macOS 14 or newer, a Swift 6 toolchain, and a device that exposes
headphone motion through CoreMotion.

### Install

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/spaceamoeba-t/tapq.git", from: "0.5.0")
```

and the product to the target that uses it:

```swift
.product(name: "TapQGestures", package: "tapq")
```

In Xcode, use **File > Add Package Dependencies** with the same URL and select the
`TapQGestures` library.

### Declare the motion permission

The one key your app's `Info.plist` needs is `NSMotionUsageDescription`:

```xml
<key>NSMotionUsageDescription</key>
<string>Reads headphone motion to detect nods, shakes, and taps.</string>
```

Nothing else is required — no microphone key, no speech-recognition key, no entitlement,
no network access. An app without this key is terminated on its first CoreMotion call
rather than prompted, so declare it before you run. See <doc:Permissions> for the
bundle-identity rules that decide whether the prompt appears at all.

### Read events

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

`GestureSession` is `@MainActor`: samples arrive on the main actor and the detectors they
feed are main-actor state, so `start(onEvent:)` delivers there too.

Three details in that snippet are load-bearing. `.motionLost` carries a
``MotionLossReason``, and the two arms above are why: `.neverStreamed` means no compatible
headphones were ever there, which asks the wearer to connect a pair, while
`.lostWhileStreaming` and `.silentStream` describe a stream that existed and stopped.
Collapsing them into one message tells someone with no AirPods to reconnect the AirPods
they do not have. `.calibrated(from:)` overlays whatever
calibration the store holds onto the defaults, and silently keeps the defaults when nothing
is stored — running uncalibrated is legal, and telling the wearer about it is your job (see
<doc:Calibration>). And the session must be retained: releasing it releases the detector
and the CoreMotion subscription with it.

### Or consume the stream

`events()` delivers the same events as an `AsyncStream`. One session drives one stream;
ending consumption — a `break`, a cancelled task, or dropping the stream — stops the
session.

```swift
@MainActor
func streamGestures(_ session: GestureSession) async {
    for await event in session.events() {
        switch event {
        case .headGesture(.nod): approve()
        case .headGesture(.shake): deny()
        default: break
        }
    }
}
```

### Check what the machine can do first

On a Mac with no compatible headphones paired there is no head motion at all, and an app
that silently waits for a nod that can never arrive is indistinguishable from a broken one.

```swift
let capabilities = GestureCapabilities.current()
if !capabilities.headphoneMotion {
    // Offer the on-screen path instead.
}
```

``GestureCapabilities/current()`` is a live query rather than a snapshot taken at launch,
so re-read it after a headphone connect or disconnect.

## See Also

- <doc:Permissions>
- <doc:Calibration>
- <doc:Testing>
