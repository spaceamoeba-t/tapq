import Foundation
import TapQContracts
import TapQInteractionBaseline
import AVFoundation

/// Speaks queued utterances through the system synthesizer with priority and preemption.
/// A higher-priority utterance (an approval request) interrupts a lower one (a status update).
@MainActor public final class SpeechEngine: NSObject, SpeechPresenting, SpeechActivitySignaling {
    private let synth = AVSpeechSynthesizer()
    private var queue = PrioritySpeechQueue()
    private var utteranceItems: [ObjectIdentifier: SpeechQueueItem] = [:]
    private var currentUtterance: AVSpeechUtterance?
    private var diagnostics = TapQDiagnosticEmitter(category: "Speech")

    public private(set) var isSpeaking = false
    public var onSpeakingChange: (@MainActor (Bool) -> Void)?

    /// Test seam (see setGestureHandlerForTesting idiom): when set, `pump()` never starts
    /// the system synthesizer and cancellation completes synchronously — tests drive the
    /// utterance lifecycle with `finishCurrentUtteranceForTesting()`.
    var synthesisForTesting: ((String) -> Void)?

    func finishCurrentUtteranceForTesting() {
        guard let currentUtterance else { return }
        complete(ObjectIdentifier(currentUtterance))
    }

    public var voiceIdentifier: String?
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    public override init() {
        super.init()
        synth.delegate = self
    }

    public init(diagnosticSink: any TapQDiagnosticSink) {
        self.diagnostics = TapQDiagnosticEmitter(category: "Speech", sink: diagnosticSink)
        super.init()
        synth.delegate = self
    }

    public func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)? = nil) {
        diagnostics.record("utterance.enqueued",
                           fields: ["priority": "\(priority)", "length": "\(text.count)"])
        let item = SpeechQueueItem(text: text, priority: priority, onFinish: onFinish)
        let shouldPreempt = queue.enqueue(item)
        if shouldPreempt {
            // Preempt: cancelling the current utterance advances the queue, which will
            // pick the higher-priority item we just appended.
            cancelCurrent()
        } else {
            pump()
        }
        updateActivity()
    }

    public func stopAll() {
        if queue.isBusy {
            diagnostics.record("utterance.interrupted", fields: ["queued": "\(queue.pendingCount)"])
        }
        let pending = queue.removeAllPending()
        for item in pending { item.onFinish?() }
        if queue.current != nil { cancelCurrent() }
        updateActivity()
    }

    /// Real synthesis cancels through the synthesizer (didCancel advances the queue);
    /// under the test seam there is no synthesizer, so complete the item directly.
    private func cancelCurrent() {
        if synthesisForTesting != nil {
            finishCurrentUtteranceForTesting()
        } else {
            synth.stopSpeaking(at: .immediate)
        }
    }

    private func pump() {
        guard let item = queue.startNext() else { return }

        let utterance = AVSpeechUtterance(string: item.text)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = rate
        utteranceItems[ObjectIdentifier(utterance)] = item
        currentUtterance = utterance
        if let synthesisForTesting {
            synthesisForTesting(item.text)
        } else {
            synth.speak(utterance)
        }
    }

    private func complete(_ key: ObjectIdentifier) {
        let item = utteranceItems.removeValue(forKey: key)
        if let item {
            diagnostics.record("utterance.finished", fields: ["length": "\(item.text.count)"])
            if queue.completeCurrent(id: item.id) != nil {
                currentUtterance = nil
            }
        }
        item?.onFinish?()
        pump()
        updateActivity()
    }

    /// The busy signal covers the WHOLE pipeline (speaking + queued), so the voice
    /// channel stays closed until a TTS backlog fully drains.
    private func updateActivity() {
        let busy = queue.isBusy
        guard busy != isSpeaking else { return }
        isSpeaking = busy
        diagnostics.record(busy ? "activity.busy" : "activity.idle")
        onSpeakingChange?(busy)
    }
}

extension SpeechEngine: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.complete(key) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.complete(key) }
    }
}
