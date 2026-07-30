import Foundation
import TapQCLI
import TapQContextBaseline
import TapQDetectionBaseline
#if canImport(TapQAppleAdapters)
import TapQAppleAdapters
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct TapQMain {
    @MainActor
    static func main() async {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let executableArgument = CommandLine.arguments.first ?? "tapq"
        let executableURL = resolveExecutableURL(
            executableArgument,
            currentDirectory: currentDirectory,
            environment: ProcessInfo.processInfo.environment
        )

        #if canImport(TapQAppleAdapters)
        let capture: (any TapQMotionCapturing)? = AppleHeadphoneMotionCapture()
        let runtime: (any TapQRuntimeServing)? = AppleTapQRuntimeService()
        let scorerLoader: ((URL) async throws -> any MotionWindowScoring)? = { url in
            try await CoreMLMotionScorer.load(modelURL: url)
        }
        #else
        let capture: (any TapQMotionCapturing)? = nil
        let runtime: (any TapQRuntimeServing)? = nil
        let scorerLoader: ((URL) async throws -> any MotionWindowScoring)? = nil
        #endif

        // The reasoner backend exists only where Foundation Models does, so the triple
        // guard — framework, OS version, device eligibility — lives here rather than in
        // the portable CLI. An ineligible device throws a named reason rather than
        // yielding nothing silently, so the host can report why it degraded.
        #if canImport(FoundationModels)
        let reasonerLoader: TapQReasonerLoading? = { config, diagnostics in
            if #available(macOS 26.0, iOS 26.0, *), FoundationModelReasoner.isSupported {
                let reasoner = FoundationModelReasoner(
                    config: config,
                    diagnosticSink: diagnostics
                )
                // Warm the instructions prefix and the model assets now, not inside the
                // first approval's timeout budget.
                reasoner.prewarm()
                return reasoner
            }
            throw TapQReasonerUnavailableError.modelUnavailable
        }
        #else
        let reasonerLoader: TapQReasonerLoading? = nil
        #endif

        let application = TapQCLIApplication(
            motionCapture: capture,
            runtimeService: runtime,
            motionScorerLoader: scorerLoader,
            reasonerLoader: reasonerLoader,
            benchReasonerLoader: reasonerLoader,
            executableURL: executableURL,
            currentDirectory: currentDirectory
        )
        let status = await application.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(status)
    }

    private static func resolveExecutableURL(
        _ argument: String,
        currentDirectory: URL,
        environment: [String: String]
    ) -> URL {
        if argument.contains("/") {
            return URL(fileURLWithPath: argument, relativeTo: currentDirectory).standardizedFileURL
        }

        for component in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false) {
            let directory = component.isEmpty
                ? currentDirectory
                : URL(fileURLWithPath: String(component), isDirectory: true)
            let candidate = directory.appendingPathComponent(argument).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return currentDirectory.appendingPathComponent(argument).standardizedFileURL
    }
}

#if canImport(TapQAppleAdapters)
@MainActor
private final class AppleHeadphoneMotionCapture: TapQMotionCapturing {
    private let detector = HeadGestureDetector()
    private var health = MotionCaptureHealth()

    func capture(
        for duration: TimeInterval,
        onSample: @escaping @MainActor (HeadMotionSample) -> Void
    ) async throws {
        health = MotionCaptureHealth()
        detector.onMotionLost = { [weak self] in self?.health.recordLoss() }
        guard detector.startCapture(onSample: { [weak self] sample in
            self?.health.recordSample()
            onSample(sample)
        }) else {
            detector.onMotionLost = nil
            throw TapQMotionCaptureError.unavailable
        }
        defer {
            detector.stopCapture()
            detector.onMotionLost = nil
        }

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        if let failure = health.failure { throw failure }
    }
}
#endif
