# GestureBar

A menu-bar app that starts a `GestureSession` and prints what it detects. It is the
smallest thing that exercises the SDK end to end on real hardware: capability status,
start/stop, and the last five `GestureEvent`s as text.

The whole app is one file,
[`Sources/GestureBar/GestureBarApp.swift`](Sources/GestureBar/GestureBarApp.swift).

## Build and run

From the repository root:

```bash
swift build --package-path Examples/GestureBar
Examples/GestureBar/scripts/package-example-app.sh   # debug; pass `release` for release
open Examples/GestureBar/build/GestureBar.app
```

The packaging step is not optional if you want real motion. TCC records a permission
decision against a code-signed bundle identity, and a bare SwiftPM binary has no stable
one — run it directly and CoreMotion is denied or the prompt never sticks. The script
assembles `build/GestureBar.app` from the built product and `Info.plist`, signs it
ad-hoc (`TAPQ_SIGN_IDENTITY` overrides the identity, as in the main runtime script), and
verifies both the bundle identifier and the motion usage key.

The app is an `LSUIElement`, so it has no Dock icon and no window. Look for the waveform
in the menu bar.

## First run

1. Connect AirPods (or another device that reports headphone motion) and put them in.
2. Open the menu. **Headphone motion** should read `yes`. If it reads `no`, macOS has not
   granted motion access yet, or no compatible device is connected.
3. Press **Start**. The first press triggers the system motion prompt — the string comes
   from `NSMotionUsageDescription` in `Info.plist`.
4. Allow it, then double-nod. `nod` appears in the event list. A single nod does not:
   every command in the vocabulary is confirmed by a repeat of the same motion.

To see the prompt again, clear the recorded decision:

```bash
tccutil reset Motion ai.tapq.example.gesturebar
```

Nothing else is requested. There is no microphone key, no speech key, and no
entitlements file — a CI check fails the build if this example ever asks for them.

## A note on the dependency form

This example depends on the repository it lives in:

```swift
.package(name: "TapQOpen", path: "../..")
```

so a change to the SDK is visible here without a tag. A real consumer uses the versioned
form instead:

```swift
.package(url: "https://github.com/spaceamoeba-t/tapq.git", from: "0.5.0")
```

The `name:` argument exists because SwiftPM derives a path dependency's identity from the
checkout's directory name, which is not stable across clones.
