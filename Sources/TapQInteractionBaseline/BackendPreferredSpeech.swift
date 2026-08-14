import Foundation
import TapQContracts

/// Speaks notifications in the voice backend's own voice when the backend can take them,
/// and in TapQ's synthesizer whenever it cannot.
///
/// The narrowness is the design. A duplex backend renders text by generating a response
/// from it, and a generated response is free to paraphrase — so the only utterances routed
/// here are the ones where a paraphrase costs nothing: `.notification`. Everything at
/// `.approval` (and everything at `.progress`, which is never worth a round trip) goes to
/// the engine verbatim, because an approval sentence names what the wearer is authorizing
/// and must arrive exactly as TapQ wrote it. No model gets to rewrite consent.
///
/// The route is a closure rather than a `VoiceBackendCommandProvider` reference so this
/// module keeps its one-way dependency on `TapQContracts`, and so the fallback is testable
/// without a backend at all. `route` returns whether the backend took the utterance; a
/// `false` — closed session, an open user turn, a response already in flight — falls
/// straight through to the engine, so a declined route is silent, never a lost utterance.
///
/// On a transcript-only backend (the Apple path) this is a no-op by construction: that
/// adapter's `requestResponse` speaks through the very same `SpeechPresenting` this
/// decorator wraps.
@MainActor public final class BackendPreferredSpeech: SpeechPresenting {
    /// Attempts to speak `text` through the backend, reporting whether it was taken.
    /// Composition passes `VoiceBackendCommandProvider.speakViaBackend`.
    public typealias SpeechRouting = @MainActor (String) -> Bool

    private let engine: any SpeechPresenting
    private let route: SpeechRouting
    private let diagnostics: TapQDiagnosticEmitter

    public init(wrapping engine: any SpeechPresenting,
                route: @escaping SpeechRouting,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.engine = engine
        self.route = route
        self.diagnostics = TapQDiagnosticEmitter(category: "BackendSpeech", sink: diagnosticSink)
    }

    /// Routed utterances call `onFinish` as soon as the backend accepts them.
    ///
    /// The backend reports acceptance, not completion — `requestResponse` has no finish
    /// callback to relay — and callers use `onFinish` to sequence what happens next. Firing
    /// it on acceptance keeps every caller moving at the same point it does today; holding
    /// it for a completion signal that never arrives would strand them. The window that
    /// opens next is still protected: the provider knows a response is pending and defers
    /// the user turn rather than listening over the backend's own voice.
    public func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
        guard priority == .notification else {
            engine.speak(text, priority: priority, onFinish: onFinish)
            return
        }
        guard route(text) else {
            diagnostics.record("utterance.spoken_locally", fields: ["reason": "route_declined"])
            engine.speak(text, priority: priority, onFinish: onFinish)
            return
        }
        diagnostics.record("utterance.spoken_by_backend", fields: ["length": "\(text.count)"])
        onFinish?()
    }

    /// Stops the local engine. A routed response is the backend's to end: cancelling it
    /// requires barge-in the backend may not have, and the provider already cancels the
    /// ones it must (window teardown, match resolution) through its own suppression paths.
    public func stopAll() {
        engine.stopAll()
    }
}
