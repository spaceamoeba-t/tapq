import Foundation
#if os(macOS)
import CoreAudio

/// The system default input device: which one it is, and what it is called.
///
/// `MicrophonePCMCapture`'s `capture.opened` line names the microphone with it. Neither call
/// throws or traps: every failure is an answer, nil or `"unknown"`. (It lived beside
/// `SystemInputVolume`, which was deleted with the legacy loop on 2026-10-08.)
enum DefaultInputDevice {
    /// The system default input device, or nil when there is none or CoreAudio did not answer.
    static func id() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil,
                                         &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// The device's name, trimmed, or `"unknown"` for a device with no name or a CoreAudio
    /// call that did not answer.
    static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name else { return "unknown" }
        let resolved = (name as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? "unknown" : resolved
    }
}
#endif
