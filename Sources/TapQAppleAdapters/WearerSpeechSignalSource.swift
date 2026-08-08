import Foundation
import TapQContracts
import TapQDetectionBaseline

/// Owns a `WearerSpeechMonitor` and exposes it as the `WearerSpeechSignaling` contract,
/// with multicast support for multiple independent consumers. Each child signal returned
/// by `makeSignal()` has its own single-observer slot and reads shared state from the
/// source -- the "add a multicast on the implementation" escape hatch that
/// `WearerSpeech.swift:27-31` anticipates.
///
/// Conforms to `MotionSampleObserving` so `HeadGestureDetector.setMotionSampleObserver`
/// can attach it as a secondary consumer of the motion sample stream.
@MainActor public final class WearerSpeechSignalSource: MotionSampleObserving {
    private let monitor: WearerSpeechMonitor

    /// Whether the source has been attached to a motion stream via
    /// `HeadGestureDetector.setMotionSampleObserver`. Set externally after attachment.
    public var isAttached: Bool = false

    /// All live child signals. Children are held strongly; they hold the source weakly.
    private var children: [ChildSignal] = []

    public init(config: WearerSpeechConfig = .init(),
                monotonicNow: @escaping () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                }) {
        self.monitor = WearerSpeechMonitor(config: config, monotonicNow: monotonicNow)
        self.monitor.onTransition = { [weak self] transition in
            self?.broadcastTransition(transition)
        }
    }

    /// Creates an independent child signal with its own single-observer callback slot.
    /// Multiple children can coexist; each observes every transition.
    public func makeSignal() -> any WearerSpeechSignaling {
        let child = ChildSignal(source: self)
        children.append(child)
        return child
    }

    // MARK: - MotionSampleObserving

    public func ingest(_ sample: HeadMotionSample) {
        monitor.ingest(sample)
    }

    public func streamInterrupted() {
        monitor.streamInterrupted()
    }

    // MARK: - Internal state for children

    fileprivate var isWearerSpeaking: Bool {
        monitor.state == .speaking
    }

    fileprivate var isSignalAvailable: Bool {
        isAttached && monitor.isFresh() && (monitor.lastSampleHadPerAxisData)
    }

    // MARK: - Multicast

    private func broadcastTransition(_ transition: WearerSpeechTransition) {
        let speaking = monitor.state == .speaking
        for child in children {
            child.onWearerSpeakingChange?(speaking)
        }
    }
}

/// One child handle into a shared `WearerSpeechSignalSource`. Reads state from the
/// source and owns its own observer callback -- the single-observer pattern the contract
/// documents, replicated per child.
@MainActor private final class ChildSignal: WearerSpeechSignaling {
    private weak var source: WearerSpeechSignalSource?

    var isWearerSpeaking: Bool {
        source?.isWearerSpeaking ?? false
    }

    var isSignalAvailable: Bool {
        source?.isSignalAvailable ?? false
    }

    var onWearerSpeakingChange: (@MainActor (Bool) -> Void)?

    init(source: WearerSpeechSignalSource) {
        self.source = source
    }
}
