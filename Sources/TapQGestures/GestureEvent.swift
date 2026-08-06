import Foundation

/// Everything a `GestureSession` can report, fanned into one stream.
///
/// ## Why the gestures are doubled
///
/// A single nod never fires. Neither does a single shake, tilt, or tap. Every command in
/// this enum is confirmed by a *repeat* of the same motion inside a short pairing window,
/// with a minimum gap that rejects the first motion's own rebound. That is a deliberate
/// trade: TapQ's events approve or reject an AI agent's proposed action, so a false
/// positive is far more expensive than a missed detection. Nodding along to music, glancing
/// down at the keyboard, or bumping an earbud while adjusting it all produce single
/// excursions, and single excursions are silence. Two deliberate nods are not an accident.
///
/// The pairing windows and amplitude thresholds live in the raw tier
/// (`HeadGestureConfig`, `TapConfig`, `TiltConfig`, `SwipeConfig`) and are what calibration
/// tunes; the doubling itself is structural and is not configurable.
///
/// ## Handling
///
/// This enum is **not frozen**. New device families and input channels will arrive as new
/// cases in minor releases, so `switch` over it with a `default` (or `@unknown default`)
/// clause. Adding a case is not treated as a breaking change.
public enum GestureEvent: Sendable, Equatable {
    /// A confirmed double nod or double shake.
    case headGesture(HeadGesture)
    /// A confirmed double tap on the body of an earbud.
    case tap(TapCommand)
    /// A confirmed double lateral tilt (ear toward shoulder).
    case tilt(TiltCommand)
    /// An experimental motion-derived finger swipe; delivered only when
    /// `Configuration.motionSwipeDetectionEnabled` is set.
    case motionSwipe(MotionSwipeCommand)
    /// A stem swipe inferred from the system output volume (macOS only).
    case volumeSwipe(VolumeSwipeCommand)
    /// The motion channel ended, carrying why. The session keeps running; a later valid
    /// sample produces `motionRestored`.
    ///
    /// Branch on the reason rather than treating every outage as a disconnect:
    /// `.neverStreamed` means no headphones were ever there (offer a connect prompt),
    /// while `.lostWhileStreaming` means a live stream died under the user's ear.
    case motionLost(MotionLossReason)
    /// Headphone motion resumed after an interruption or a reported outage.
    case motionRestored
}
