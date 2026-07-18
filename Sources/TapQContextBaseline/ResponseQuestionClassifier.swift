import Foundation
import TapQContracts

/// What a classifier found in Claude's final text reply.
///
/// The case is deliberately named `noQuestion` (not `none`): several call sites return
/// `ResponseQuestionClassification?`, where a bare `.none` would silently resolve to
/// `Optional.none` — a different meaning ("classifier can't answer") entirely.
public enum ResponseQuestionClassification: Equatable, Sendable {
    /// The reply doesn't ask the user anything answerable hands-free.
    case noQuestion
    /// The reply offers 2+ alternatives and asks the user to pick one.
    case multiOption(question: String, options: [SelectionOption])
    /// The reply asks a single question answerable with yes or no.
    case yesNo(question: String)
}

/// A strategy that reads a reply and extracts its question, if any.
///
/// Returning `nil` means "this classifier cannot answer" (model unavailable, error,
/// timeout) and the caller may fall back to another classifier. Returning
/// `.noQuestion` is an authoritative "there is nothing to ask".
public protocol ResponseQuestionClassifying: Sendable {
    func classify(_ text: String) async -> ResponseQuestionClassification?
}

/// Primary-then-fallback composition. The primary's `nil` ("can't answer") falls
/// through; its `.noQuestion` is authoritative and does NOT fall through — the
/// fallback regex must never resurrect a false positive the model rejected.
public struct QuestionClassifierChain: ResponseQuestionClassifying {
    let primary: (any ResponseQuestionClassifying)?
    let fallback: any ResponseQuestionClassifying

    public init(primary: (any ResponseQuestionClassifying)?,
                fallback: any ResponseQuestionClassifying) {
        self.primary = primary
        self.fallback = fallback
    }

    public func classify(_ text: String) async -> ResponseQuestionClassification? {
        if let primary, let result = await primary.classify(text) { return result }
        return await fallback.classify(text)
    }
}

/// Builds the best chain this machine supports: Apple's on-device Foundation Models
/// classifier when available, always backed by deterministic heuristics. Hosts can
/// still inject another primary classifier without changing runtime policy.
public enum QuestionClassifierFactory {
    public static func make(
        primary: (any ResponseQuestionClassifying)? = nil,
        allowFoundationModel: Bool = true
    ) -> any ResponseQuestionClassifying {
        if let primary {
            return QuestionClassifierChain(
                primary: primary,
                fallback: HeuristicQuestionClassifier()
            )
        }

        #if canImport(FoundationModels)
        if allowFoundationModel,
           #available(macOS 26.0, iOS 26.0, *),
           FoundationModelClassifier.isSupported {
            return QuestionClassifierChain(
                primary: FoundationModelClassifier(),
                fallback: HeuristicQuestionClassifier()
            )
        }
        #endif

        return QuestionClassifierChain(primary: nil, fallback: HeuristicQuestionClassifier())
    }
}
