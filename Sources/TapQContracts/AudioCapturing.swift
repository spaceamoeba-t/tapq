import Foundation

public enum AudioDeviceFailure: Sendable, Equatable {
    /// AVAudioEngineConfigurationChange: reopen (D7).
    case configurationChanged
    /// Device gone, start refused → fatal.
    case unavailable(String)
}

/// The microphone, as speech input needs it.
@MainActor public protocol AudioCapturing: AnyObject {
    /// Blocks in capture order. `chunk.timestamp` is the capture-clock instant of its
    /// first sample (07-9: AVAudioTime.seconds(forHostTime:), not hostTime/1e9).
    func start(onBlock: @escaping @MainActor (VoiceAudioChunk) -> Void,
               onFailure: @escaping @MainActor (AudioDeviceFailure) -> Void) throws
    func stop()
}
