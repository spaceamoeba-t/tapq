import Foundation
import TapQCLI
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
        #else
        let capture: (any TapQMotionCapturing)? = nil
        let runtime: (any TapQRuntimeServing)? = nil
        #endif

        let application = TapQCLIApplication(
            motionCapture: capture,
            runtimeService: runtime,
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
