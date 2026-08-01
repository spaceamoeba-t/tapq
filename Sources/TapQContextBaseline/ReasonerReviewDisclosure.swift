/// Privacy policy for the free-text rationale persisted by the local shadow-review log.
///
/// Closed-schema contexts may retain the model's bounded note. Open-schema MCP contexts
/// may contain arbitrary connector values, and a model instruction not to repeat them is
/// not a redaction boundary, so their free-text note is always discarded. Confidence is
/// also model-generated numeric output with enough precision to echo an argument value,
/// so MCP rows discard it too. The review log still records the decision's tier, closed
/// rationale code, and outcome.
package enum ReasonerReviewDisclosure {
    package static func persistedNote(
        from decision: ReasonerDecision?,
        context: ReasonerContext
    ) -> String? {
        guard context.toolInput == nil else { return nil }
        return decision?.rationale.note
    }

    package static func persistedConfidence(
        from decision: ReasonerDecision?,
        context: ReasonerContext
    ) -> Double? {
        guard context.toolInput == nil else { return nil }
        return decision?.confidence
    }
}
