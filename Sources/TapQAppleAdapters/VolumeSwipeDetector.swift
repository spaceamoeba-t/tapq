import Foundation
import TapQContracts
import TapQDetectionBaseline
import CoreAudio

/// Observes the macOS default output volume and forwards readings to the portable
/// `VolumeSwipeAnalyzer`.
@MainActor public final class VolumeSwipeDetector: VolumeSwipeProviding {
    private var onSwipe: (@MainActor (VolumeSwipeCommand) -> Void)?
    private var running = false
    private let diagnostics: TapQDiagnosticEmitter
    private var analyzer = VolumeSwipeAnalyzer()
    private var deviceID: AudioDeviceID = 0
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    public var sensitivity: Float32 {
        get { Float32(analyzer.sensitivity) }
        set { analyzer.sensitivity = Double(newValue) }
    }

    public var debounceSeconds: TimeInterval {
        get { analyzer.debounceSeconds }
        set { analyzer.debounceSeconds = newValue }
    }

    public init(diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        diagnostics = TapQDiagnosticEmitter(category: "VolumeSwipe", sink: diagnosticSink)
    }

    public func start(onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void) {
        guard !running else { return }
        self.onSwipe = onSwipe
        deviceID = Self.defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else {
            diagnostics.record("output_device.unavailable", level: .warning)
            return
        }
        diagnostics.record("listening.started", fields: ["device": "\(deviceID)"])
        analyzer.reset(initialVolume: Double(Self.getVolume(deviceID)))
        running = true

        var address = Self.volumeAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.volumeChanged() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
    }

    public func stop() {
        guard running else { return }
        running = false
        onSwipe = nil
        if let block = listenerBlock {
            var address = Self.volumeAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            listenerBlock = nil
        }
        analyzer.reset()
    }

    private func volumeChanged() {
        processVolumeChange(Self.getVolume(deviceID), at: ProcessInfo.processInfo.systemUptime)
    }

    func processVolumeChange(_ newVolume: Float32, at time: TimeInterval) {
        guard running else { return }
        guard let direction = analyzer.ingest(volume: Double(newVolume), at: time) else { return }
        diagnostics.record("swipe.detected", fields: ["direction": "\(direction)"])
        onSwipe?(direction)
    }

    func beginForTesting(initialVolume: Float32,
                         onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void) {
        self.onSwipe = onSwipe
        analyzer.reset(initialVolume: Double(initialVolume))
        running = true
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private static func getVolume(_ device: AudioDeviceID) -> Float32 {
        var address = volumeAddress()
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return volume
    }
}
