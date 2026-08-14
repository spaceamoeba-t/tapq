import Foundation
import TapQDetectionBaseline
#if canImport(CoreML)
import CoreML

public enum CoreMLMotionScorerError: Error, LocalizedError, Equatable {
    case metadataMissing(String)
    case layoutMismatch(expected: String, found: String)
    case classesMismatch(expected: String, found: String)
    case windowLengthMismatch(expected: Int, found: String)
    case unsupportedModel(String)
    case windowShapeMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .metadataMissing(let key):
            return "The model does not declare \(key); it was not exported by ml/tapq1/export.py or predates the current contract."
        case .layoutMismatch(let expected, let found):
            return "The model was trained for feature layout '\(found)' but this runtime speaks '\(expected)'. Re-export the model against the current layout."
        case .classesMismatch(let expected, let found):
            return "The model declares classes '\(found)' but this runtime expects '\(expected)'."
        case .windowLengthMismatch(let expected, let found):
            return "The model declares window length \(found) but this runtime expects \(expected)."
        case .unsupportedModel(let reason):
            return "Unsupported TapQ-1 model: \(reason)"
        case .windowShapeMismatch(let reason):
            return "Encoder window does not match the model input: \(reason)"
        }
    }
}

/// Core ML backend for the TapQ-1 stage-1 encoder. Loads a model exported by
/// `ml/tapq1/export.py`, refuses any model whose embedded contract (feature-layout
/// version, class order, window length) disagrees with this runtime, and scores
/// windows on whatever compute units Core ML selects (ANE-eligible).
public final class CoreMLMotionScorer: MotionWindowScoring {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    public let windowLength: Int

    /// Loads from a `.mlpackage`/`.mlmodel` (compiled on the fly) or a pre-compiled
    /// `.mlmodelc` directory.
    public static func load(
        modelURL: URL,
        configuration: MLModelConfiguration = MLModelConfiguration()
    ) async throws -> CoreMLMotionScorer {
        let compiledURL = modelURL.pathExtension == "mlmodelc"
            ? modelURL
            : try await MLModel.compileModel(at: modelURL)
        return try CoreMLMotionScorer(
            model: MLModel(contentsOf: compiledURL, configuration: configuration)
        )
    }

    init(model: MLModel) throws {
        self.model = model
        let description = model.modelDescription

        let metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let layout = metadata[TapQ1ModelMetadata.featureLayoutKey] else {
            throw CoreMLMotionScorerError.metadataMissing(TapQ1ModelMetadata.featureLayoutKey)
        }
        guard layout == EncoderFeatureLayout.version else {
            throw CoreMLMotionScorerError.layoutMismatch(
                expected: EncoderFeatureLayout.version, found: layout)
        }
        guard let classes = metadata[TapQ1ModelMetadata.classesKey] else {
            throw CoreMLMotionScorerError.metadataMissing(TapQ1ModelMetadata.classesKey)
        }
        guard classes == TapQ1ModelMetadata.expectedClasses else {
            throw CoreMLMotionScorerError.classesMismatch(
                expected: TapQ1ModelMetadata.expectedClasses, found: classes)
        }
        guard let declaredWindow = metadata[TapQ1ModelMetadata.windowLengthKey] else {
            throw CoreMLMotionScorerError.metadataMissing(TapQ1ModelMetadata.windowLengthKey)
        }
        guard Int(declaredWindow) == EncoderFeatureLayout.windowLength else {
            throw CoreMLMotionScorerError.windowLengthMismatch(
                expected: EncoderFeatureLayout.windowLength, found: declaredWindow)
        }
        windowLength = EncoderFeatureLayout.windowLength

        guard description.inputDescriptionsByName.count == 1,
              let input = description.inputDescriptionsByName.first,
              let inputConstraint = input.value.multiArrayConstraint else {
            throw CoreMLMotionScorerError.unsupportedModel(
                "expected exactly one multi-array input")
        }
        let expectedInput = [1, EncoderFeatureLayout.windowLength,
                             EncoderFeatureLayout.channelCount]
        guard inputConstraint.shape.map(\.intValue) == expectedInput else {
            throw CoreMLMotionScorerError.unsupportedModel(
                "input shape \(inputConstraint.shape) != \(expectedInput)")
        }
        inputName = input.key

        guard description.outputDescriptionsByName.count == 1,
              let output = description.outputDescriptionsByName.first,
              let outputConstraint = output.value.multiArrayConstraint else {
            throw CoreMLMotionScorerError.unsupportedModel(
                "expected exactly one multi-array output")
        }
        let classCount = GestureClass.allCases.count
        guard outputConstraint.shape.map(\.intValue) == [1, classCount] else {
            throw CoreMLMotionScorerError.unsupportedModel(
                "output shape \(outputConstraint.shape) != [1, \(classCount)]")
        }
        outputName = output.key
    }

    public func score(_ window: EncoderInputWindow) throws -> GestureScores {
        guard window.features.count == windowLength else {
            throw CoreMLMotionScorerError.windowShapeMismatch(
                "\(window.features.count) rows, expected \(windowLength)")
        }
        let channelCount = EncoderFeatureLayout.channelCount
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: windowLength), NSNumber(value: channelCount)],
            dataType: .float32
        )
        var index = 0
        for row in window.features {
            guard row.count == channelCount else {
                throw CoreMLMotionScorerError.windowShapeMismatch(
                    "\(row.count) channels, expected \(channelCount)")
            }
            for value in row {
                array[index] = NSNumber(value: value)
                index += 1
            }
        }

        let prediction = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [inputName: array])
        )
        guard let scores = prediction.featureValue(for: outputName)?.multiArrayValue,
              scores.count == GestureClass.allCases.count else {
            throw CoreMLMotionScorerError.unsupportedModel(
                "prediction did not produce \(GestureClass.allCases.count) class scores")
        }
        var values: [GestureClass: Float] = [:]
        for (offset, gestureClass) in GestureClass.allCases.enumerated() {
            values[gestureClass] = scores[offset].floatValue
        }
        return GestureScores(values: values)
    }
}
#endif
