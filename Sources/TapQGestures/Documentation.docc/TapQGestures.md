# ``TapQGestures``

Embed calibrated AirPods gesture input in a macOS app.

## Overview

TapQGestures is the gesture engine behind the `tapq` runtime, packaged so another app
can use it directly. It reads headphone motion through CoreMotion, classifies it with
per-wearer calibrated thresholds, and reports the result. It contains no agent, approval,
speech, or microphone code: an app that adopts it inherits a motion permission prompt and
nothing else.

`import TapQGestures` is the whole SDK. The module re-exports the three portable modules
it is built on, so the raw tier is available without a second import.

### Two tiers

The **curated tier** is ``GestureSession`` and ``GestureEvent``: one enum of commands that
are already filtered for false positives. Every command in it is *doubled* — a single nod,
shake, tilt, or tap never fires, because these events were designed to approve or reject an
agent's proposed action, where a false positive costs more than a missed detection. Nodding
along to music produces single excursions, and single excursions are silence. The pairing
windows and amplitude thresholds are configurable; the doubling itself is structural.

The **raw tier** is `HeadMotionSample` and `MotionGesturePipeline`: complete motion samples
delivered unclassified, and a hardware-free, deterministic pipeline you can drive yourself
with your own thresholds, your own analyzers, or your own recorded data. Use it when the
curated vocabulary is too coarse, or when you are running a capture study. Both tiers are
supported; neither is a fallback for the other.

A session runs one tier at a time. Asking for the other while one is streaming is not a
programmer error and does not trap — it records a diagnostic and hands back a stream that
finishes immediately.

### Where this is going

The vocabulary is typed per body placement rather than flattened into one generic
"gesture" enum: head motion is what exists today, and a wrist or ring vocabulary would be
its own enum with its own physical meaning, under the same session, capability, and
calibration framework. A binding layer that maps vocabularies onto app-defined actions is
planned above them, so an app can express "approve" once and let the framework decide which
placement satisfies it. The tiers below that layer are not expected to change shape.

### Stability

The SDK is pre-1.0 and its enums and option structs are deliberately **not frozen**. New
device families and input channels arrive as new cases and new fields in minor releases,
which is not treated as a breaking change. Switch over ``GestureEvent`` with a `default`
(or `@unknown default`) clause, and read the ``GestureCapabilities`` properties you care
about rather than pattern-matching the whole value.

## Topics

### Essentials

- <doc:GettingStarted>
- ``GestureSession``
- ``GestureEvent``
- ``GestureCapabilities``

### Permissions and packaging

- <doc:Permissions>

### Calibrating to a wearer

- <doc:Calibration>
- ``CalibrationService``
- ``CalibrationServiceError``
- ``CalibrationStore``
- ``CalibrationProfileStoring``

### Raw motion

- <doc:RawMotion>
- ``HeadMotionSample``
- ``MotionGesturePipeline``
- ``HeadphoneMotionSource``
- ``HeadGestureDetector``
- ``VolumeSwipeDetector``
- ``CoreMLMotionScorer``
- ``CoreMLMotionScorerError``

### Testing without hardware

- <doc:Testing>
- ``ScriptedMotionSource``
- ``UnavailableMotionSource``
