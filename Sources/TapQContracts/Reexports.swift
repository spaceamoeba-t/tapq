/// Gesture vocabulary that used to be declared here.
///
/// `HeadGesture`, `VoiceCommand`, `TapCommand`, `TiltCommand`, the swipe commands, their
/// provider protocols, and the diagnostic contract now live in `TapQGestureContracts` so
/// detection can be embedded without the agent/approval domain. Re-exporting them keeps
/// `import TapQContracts` alone sufficient for every existing consumer, so the split is
/// invisible at the source level.
@_exported import TapQGestureContracts
