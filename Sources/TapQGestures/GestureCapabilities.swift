import Foundation

/// What this machine, right now, can actually detect.
///
/// Ask before you offer a gesture in your UI: on a Mac with no compatible AirPods paired
/// there is no head motion at all, and an app that silently waits for a nod that can never
/// arrive is indistinguishable from a broken one.
///
/// The field set is **not frozen** — new input channels will add fields in minor releases.
/// Read the properties you care about rather than pattern-matching the whole value.
public struct GestureCapabilities: Sendable, Equatable {
    /// Compatible headphone motion is available to this process. Drives nods, shakes,
    /// taps, tilts, and motion swipes — i.e. everything except volume swipes.
    ///
    /// Dynamic: it reflects what is paired and connected at the moment it is read, and it
    /// is deliberately `false` inside an XCTest host, where touching CoreMotion would trip
    /// a TCC permission abort.
    public let headphoneMotion: Bool

    /// Stem swipes inferred from the system output volume are compiled in. macOS only:
    /// the CoreAudio property listener this needs has no iOS equivalent.
    public let volumeSwipes: Bool

    /// The experimental motion-swipe analyzer is compiled in. Compiled in is not the same
    /// as running: it stays off until `Configuration.motionSwipeDetectionEnabled` is set,
    /// pending capture-study validation of direction separability at ~25 Hz.
    public let motionSwipes: Bool

    /// Construct a hypothetical capability set — useful for previews and for tests that
    /// need to exercise a machine other than the one they run on.
    public init(headphoneMotion: Bool, volumeSwipes: Bool, motionSwipes: Bool) {
        self.headphoneMotion = headphoneMotion
        self.volumeSwipes = volumeSwipes
        self.motionSwipes = motionSwipes
    }

    /// Capabilities of the current process and host.
    @MainActor public static func current() -> GestureCapabilities {
        GestureCapabilities(
            headphoneMotion: HeadGestureDetector.isAvailable,
            volumeSwipes: {
                #if os(macOS)
                return true
                #else
                return false
                #endif
            }(),
            motionSwipes: true
        )
    }
}
