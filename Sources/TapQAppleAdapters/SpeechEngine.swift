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

    /// Which voice speaks: a BCP-47 language tag ("en-US", "zh-CN") or a full
    /// `AVSpeechSynthesisVoice` identifier. Resolved once on assignment, not per utterance.
    ///
    /// Leaving this nil is the failure mode this property exists to prevent: AVFoundation
    /// then picks the default voice for the SYSTEM language and never looks at the text,
    /// so English prompts on a Chinese-language Mac come out of a Chinese voice — digits
    /// and unrecognized words in Chinese phonology, the rest mangled. Hosts should always
    /// set it; `TapQRuntimeConfiguration.speechVoice` carries the user's choice.
    public var voiceSelection: String? {
        didSet {
            guard voiceSelection != oldValue else { return }
            resolveSelectedVoice()
        }
    }
    private var selectedVoice: AVSpeechSynthesisVoice?
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// Accepts either spelling so callers can pin a language without knowing which
    /// concrete voice is installed. Returns nil when neither form matches.
    ///
    /// Neither AVFoundation initializer reliably fails closed. `init(language:)` returns nil
    /// for an unparseable tag on some macOS versions and the system-default voice on others
    /// — the CI runner hands back en-US Samantha for "not-a-real-voice" while a local
    /// macOS 26 machine returns nil. Accepting that substitution would reinstate the silent
    /// system-language fallback this whole property exists to remove, so both results are
    /// checked against what was actually asked for.
    static func resolveVoice(_ selection: String) -> AVSpeechSynthesisVoice? {
        if let voice = AVSpeechSynthesisVoice(identifier: selection), voice.identifier == selection {
            return voice
        }
        // The generic English selection — which is also TapQ's default — means "a good
        // English voice", not "whatever macOS considers the en-US default". On a bare
        // machine that default is Eddy, an Eloquence formant synthesizer kept for
        // accessibility users who prefer its 1980s articulation. Anyone who wants Eddy,
        // or any other specific voice, can still pin it by identifier above.
        if isGenericEnglishSelection(selection) {
            for identifier in preferredEnUSVoiceIdentifiers {
                if let voice = AVSpeechSynthesisVoice(identifier: identifier),
                   voice.identifier == identifier {
                    return voice
                }
            }
        }
        guard let voice = AVSpeechSynthesisVoice(language: selection) else { return nil }
        return languageMatches(voice.language, requested: selection) ? voice : nil
    }

    /// The downloadable Samantha tiers, best first. Apple's voice catalog for this OS
    /// generation offers exactly one high-tier US English voice — Samantha — and which
    /// identifier it registers under varies (the catalog's "premium" asset installs as
    /// `enhanced` on macOS 26), so both spellings are tried. None installed means the
    /// user never downloaded a voice, and resolution falls through to the system pick.
    /// A cloud or custom local TTS provider, when one exists, will slot in ahead of
    /// this list; today the chain is downloaded Samantha, then the system default.
    static let preferredEnUSVoiceIdentifiers = [
        "com.apple.voice.premium.en-US.Samantha",
        "com.apple.voice.enhanced.en-US.Samantha",
    ]

    /// Only "en" and "en-US" are generic: they ask for English without choosing a
    /// regional voice. "en-GB" is a deliberate regional choice and is never redirected.
    static func isGenericEnglishSelection(_ selection: String) -> Bool {
        selection.caseInsensitiveCompare("en") == .orderedSame
            || selection.caseInsensitiveCompare("en-US") == .orderedSame
    }

    /// Primary-subtag comparison: "en" accepts an en-US voice, and "en-GB" accepts a
    /// substituted en-US one, because a regional substitution still speaks the requested
    /// language. "not-a-real-voice" never accepts en-US. Substituting within a language is
    /// acceptable; substituting across languages is the bug.
    static func languageMatches(_ language: String, requested: String) -> Bool {
        func primarySubtag(_ tag: String) -> Substring? {
            tag.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first
        }
        guard let spoken = primarySubtag(language),
              let asked = primarySubtag(requested) else { return false }
        return spoken.caseInsensitiveCompare(asked) == .orderedSame
    }

    /// Warns once at configuration time rather than per utterance: a silent fallback to
    /// the system-locale voice is exactly the bug `voiceSelection` exists to fix, so it
    /// must be visible while the user can still act on it.
    private func resolveSelectedVoice() {
        guard let voiceSelection else {
            selectedVoice = nil
            return
        }
        selectedVoice = Self.resolveVoice(voiceSelection)
        if selectedVoice == nil {
            diagnostics.record(
                "voice.unavailable",
                level: .warning,
                fields: ["selection": voiceSelection]
            )
        }
    }

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
        // Left nil, AVFoundation substitutes the system-language voice at speak time.
        utterance.voice = selectedVoice
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
