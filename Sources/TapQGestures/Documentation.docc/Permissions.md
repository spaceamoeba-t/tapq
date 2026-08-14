# Permissions

One motion permission, and the bundle identity macOS needs before it will ask for it.

## Overview

Head motion is the only thing TapQGestures asks the system for. Everything else it does —
classification, calibration, volume-swipe observation — runs on data the process already
has.

### The motion permission

Declare `NSMotionUsageDescription` in the `Info.plist` of the app that links the SDK:

```xml
<key>NSMotionUsageDescription</key>
<string>Reads headphone motion to detect nods, shakes, and taps.</string>
```

macOS presents the string when the first CoreMotion call happens. A process that reaches
CoreMotion without the key is terminated rather than prompted, which looks like a crash on
first gesture.

### Bundle identity decides whether the prompt appears

TCC records a decision against a code-signed bundle identity. A bare SwiftPM executable —
`swift run`, or the binary under `.build/` — has no stable one, so the grant either cannot
be recorded or is attached to something that changes on the next build. The result is a
process that is denied motion, or re-prompted, with no error you can catch.

Anything that needs real headphone motion therefore has to run from a signed `.app` bundle:

- an `Info.plist` at `Contents/Info.plist` carrying `NSMotionUsageDescription` and a stable
  `CFBundleIdentifier`,
- the executable at `Contents/MacOS/`,
- a code signature over the bundle (ad-hoc is enough for local development).

`Examples/GestureBar/scripts/package-example-app.sh` in this repository is that assembly in
about thirty lines: build the product, copy the binary and the plist into
`build/GestureBar.app`, `codesign --force --options runtime`, then verify the signature and
the plist key. A normal Xcode app target already produces the same shape, and needs nothing
extra beyond the usage-description key.

The prompt appears once per identity. To see it again during development, clear the
recorded decision:

```bash
tccutil reset Motion ai.tapq.example.gesturebar
```

Under XCTest there is no such identity at all, and touching CoreMotion in an unsigned test
host aborts the process. The SDK's production motion source reports itself unavailable in a
test process for exactly that reason; see <doc:Testing>.

### What is not required

- **Microphone.** The SDK has no audio capture. `NSMicrophoneUsageDescription` is not
  needed and should not be added.
- **Speech recognition.** No `NSSpeechRecognitionUsageDescription`. Voice command matching
  lives in the `tapq` runtime, not here.
- **Audio-input entitlement.** `com.apple.security.device.audio-input` is not needed, in a
  sandboxed app or out of one.
- **Network.** Detection is entirely local; the SDK opens no connections.

Stem swipes are the case that surprises people: the SDK infers them from changes in the
system output volume through a CoreAudio property listener, which reads a system-wide value
and requires no permission and no entitlement. The gesture is real hardware input, but
observing it costs nothing at the privacy layer.

## See Also

- <doc:GettingStarted>
- <doc:Testing>
