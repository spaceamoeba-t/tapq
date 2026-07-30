#if canImport(FoundationModels)
import Foundation
import FoundationModels
import TapQContracts

/// On-device stage-2 risk assessment via Apple's Foundation Models framework.
///
/// Every failure mode — no model, Apple Intelligence off, a guardrail refusal, a thrown
/// backend error, a timeout, or an answer that names a tier the contract does not have —
/// returns `nil`, which `ContextReasoning` defines as "cannot answer" and which leaves
/// the deterministic confirmation requirement untouched. Nothing this type returns can
/// make TapQ approve something it would not already have approved.
///
/// Not `@MainActor`: `assess(_:)` runs while the user is mid-gesture, and occupying the
/// UI actor would stall the interaction the assessment is about. No request text ever
/// leaves the device, and none of it reaches diagnostics.
@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelReasoner: ContextReasoning {
    /// The closed output schema. `tier` and `code` are constrained to the contract's own
    /// raw values, so an answer outside the vocabulary is rejected by the framework's
    /// constrained decoding before `ReasonerPromptContract.decision` ever has to.
    ///
    /// There is no confirmation field on purpose: what a tier costs the user is policy,
    /// and policy is not a thing a model gets to state.
    @Generable
    struct Assessment {
        @Guide(
            description: "How consequential the action is.",
            .anyOf(ReasonerPromptContract.tierValues)
        )
        var tier: String
        @Guide(
            description: "The first listed reason that applies, in precedence order.",
            .anyOf(ReasonerPromptContract.codeValues)
        )
        var code: String
        @Guide(
            description: """
                One short sentence naming the specific thing at risk. Never copy the \
                action's text into it.
                """
        )
        var note: String
        @Guide(description: "How sure you are, from 0 to 1.", .range(0.0...1.0))
        var confidence: Double
    }

    /// Whether the on-device model can answer at all. `false` covers ineligible hardware,
    /// Apple Intelligence being switched off, and assets that have not finished
    /// downloading — all of which are ordinary states, not errors.
    public static var isSupported: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private let config: ReasonerConfig
    private let diagnostics: TapQDiagnosticEmitter
    /// Held only to keep the instructions prefix and the model assets warm. Requests use
    /// a fresh session each time: a reused session accumulates a transcript, which would
    /// leak one approval's command text into the next one's prompt and grow the context
    /// window until it failed.
    private let warmSession: LanguageModelSession

    public init(
        config: ReasonerConfig = ReasonerConfig(),
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.config = config
        self.diagnostics = TapQDiagnosticEmitter(
            category: "FoundationModelReasoner",
            sink: diagnosticSink
        )
        self.warmSession = LanguageModelSession(
            instructions: ReasonerPromptContract.instructions
        )
        warmSession.prewarm()
    }

    /// Warms the model and the instructions prefix ahead of a request.
    ///
    /// The runtime calls this when an approval is enqueued, which is typically a second
    /// or more before the user finishes reacting to it — time that would otherwise be
    /// spent loading assets inside the timeout budget. Repeat calls are safe; the
    /// framework treats prewarming as a hint.
    public func prewarm() {
        warmSession.prewarm()
    }

    public func assess(_ context: ReasonerContext) async -> ReasonerDecision? {
        guard Self.isSupported else {
            diagnostics.record("reasoner.abstained", level: .warning, fields: [
                "reason": "model_unavailable",
            ])
            return nil
        }

        let started = ContinuousClock.now
        let outcome = await ReasonerDeadline.run(seconds: config.timeoutSeconds) {
            await evaluate(context)
        }
        let latency = Self.milliseconds(from: started, to: .now)

        switch outcome {
        case .completed(.decided(let decision)):
            diagnostics.record("reasoner.assessed", fields: [
                "latency_ms": latency,
                "tier": decision.riskTier.rawValue,
            ])
            return decision
        case .completed(.unmappable):
            diagnostics.record("reasoner.abstained", level: .warning, fields: [
                "latency_ms": latency,
                "reason": "unmappable_output",
            ])
            return nil
        case .completed(.failed(let reason)):
            diagnostics.record("reasoner.abstained", level: .warning, fields: [
                "latency_ms": latency,
                "reason": reason,
            ])
            return nil
        case .timedOut:
            diagnostics.record("reasoner.abstained", level: .warning, fields: [
                "latency_ms": latency,
                "reason": "timeout",
            ])
            return nil
        case .cancelled:
            diagnostics.record("reasoner.abstained", fields: [
                "latency_ms": latency,
                "reason": "cancelled",
            ])
            return nil
        }
    }

    private func evaluate(_ context: ReasonerContext) async -> Outcome {
        let session = LanguageModelSession(
            instructions: ReasonerPromptContract.instructions
        )
        do {
            let response = try await session.respond(
                to: ReasonerPromptContract.renderContext(context),
                generating: Assessment.self,
                options: GenerationOptions(sampling: .greedy)
            )
            let assessment = response.content
            guard let decision = ReasonerPromptContract.decision(
                tier: assessment.tier,
                code: assessment.code,
                note: assessment.note,
                confidence: assessment.confidence,
                config: config
            ) else { return .unmappable }
            return .decided(decision)
        } catch let error as LanguageModelSession.GenerationError {
            return .failed(Self.reason(for: error))
        } catch {
            return .failed("backend_error")
        }
    }

    /// Maps a backend error to a short, closed diagnostic kind. Only the case is
    /// reported: `GenerationError.Context.debugDescription` and a refusal's explanation
    /// can both quote the prompt, and the prompt is the user's command line.
    private static func reason(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: return "context_window_exceeded"
        case .assetsUnavailable: return "assets_unavailable"
        case .guardrailViolation: return "guardrail_violation"
        case .unsupportedGuide: return "unsupported_guide"
        case .unsupportedLanguageOrLocale: return "unsupported_locale"
        case .decodingFailure: return "decoding_failure"
        case .rateLimited: return "rate_limited"
        case .concurrentRequests: return "concurrent_requests"
        case .refusal: return "refusal"
        default: return "backend_error"
        }
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> String {
        let components = start.duration(to: end).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
        return String(format: "%.0f", milliseconds)
    }

    /// How one generation attempt ended, kept separate from the returned decision so the
    /// abstention paths worth acting on — an unreadable answer, a guardrail refusal, a
    /// backend error — stay distinguishable in diagnostics.
    private enum Outcome: Sendable {
        case decided(ReasonerDecision)
        case unmappable
        case failed(String)
    }
}
#endif
