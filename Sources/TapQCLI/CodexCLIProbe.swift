import Foundation
import TapQPOSIXSupport

/// The observable result of one best-effort Codex CLI diagnostic command.
///
/// TapQ never uses this runner to change Codex configuration. The public shape exists so
/// embedders and tests can supply a process boundary without depending on a local Codex install.
public enum CodexCLICommandResult: Equatable, Sendable {
    /// The resolved command could not be launched, completed, or drained within its bounds.
    /// Executable absence is tracked separately by the resolver.
    case unavailable
    case completed(status: Int32, standardOutput: String, standardError: String)
}

enum CodexFeatureState: Equatable {
    case enabled(stage: String)
    case disabled(stage: String)
    case unknown
}

enum CodexCLIAvailability: Equatable {
    case notFound
    case probeFailed
    case detected
}

struct CodexCLIActivationStatus: Equatable {
    let availability: CodexCLIAvailability
    let executablePath: String?
    let version: String?
    let hooks: CodexFeatureState
    let defaultModeRequestUserInput: CodexFeatureState

    var isAvailable: Bool { availability == .detected }

    var isBelowTestedLifecycleFloor: Bool? {
        version.flatMap(CodexCLIProbe.isBelowTestedLifecycleFloor)
    }

    static let notFound = CodexCLIActivationStatus(
        availability: .notFound,
        executablePath: nil,
        version: nil,
        hooks: .unknown,
        defaultModeRequestUserInput: .unknown
    )
}

enum CodexCLIProbe {
    static let testedLifecycleFloor = "0.142.5"
    private static let maximumVersionTokenBytes = 128

    static func probe(
        executablePath: String? = nil,
        executableWasResolved: Bool = true,
        using run: ([String]) -> CodexCLICommandResult
    ) -> CodexCLIActivationStatus {
        guard executableWasResolved else { return .notFound }
        let versionResult = run(["--version"])
        guard case .completed(let versionStatus, let versionOutput, let versionError) =
                versionResult else {
            return CodexCLIActivationStatus(
                availability: .probeFailed,
                executablePath: executablePath,
                version: nil,
                hooks: .unknown,
                defaultModeRequestUserInput: .unknown
            )
        }

        let version = versionStatus == 0
            ? parseVersion(from: versionOutput + "\n" + versionError)
            : nil
        let featuresResult = run(["features", "list"])
        guard case .completed(let featureStatus, let featureOutput, let featureError) =
                featuresResult,
              featureStatus == 0 else {
            return CodexCLIActivationStatus(
                availability: versionStatus == 0 ? .detected : .probeFailed,
                executablePath: executablePath,
                version: version,
                hooks: .unknown,
                defaultModeRequestUserInput: .unknown
            )
        }

        let features = featureOutput + "\n" + featureError
        return CodexCLIActivationStatus(
            availability: .detected,
            executablePath: executablePath,
            version: version,
            hooks: parseFeature(named: "hooks", from: features),
            defaultModeRequestUserInput: parseFeature(
                named: "default_mode_request_user_input",
                from: features
            )
        )
    }

    static func parseVersion(from output: String) -> String? {
        let punctuation = CharacterSet(charactersIn: ",;()[]{}")
        for line in output.components(separatedBy: .newlines) {
            let tokens = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard tokens.contains(where: { $0.lowercased().contains("codex") }) else {
                continue
            }
            for token in tokens {
                let candidate = token.trimmingCharacters(in: punctuation)
                guard isSafeVersionToken(candidate) else { continue }
                return candidate
            }
        }
        return nil
    }

    /// Version text is rendered directly in terminal diagnostics. Accept the numeric core and
    /// SemVer-shaped ASCII prerelease/build identifiers, but never relay arbitrary CLI output.
    private static func isSafeVersionToken(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.utf8.count <= maximumVersionTokenBytes else {
            return false
        }
        let buildPieces = candidate.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard buildPieces.count <= 2,
              buildPieces.count == 1 || isSafeVersionSuffix(buildPieces[1]) else {
            return false
        }
        let releasePieces = buildPieces[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard releasePieces.count <= 2,
              releasePieces.count == 1 || isSafeVersionSuffix(releasePieces[1]) else {
            return false
        }
        let numericComponents = releasePieces[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return numericComponents.count >= 2 && numericComponents.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!
            }
        }
    }

    private static func isSafeVersionSuffix(_ suffix: Substring) -> Bool {
        let identifiers = suffix.split(separator: ".", omittingEmptySubsequences: false)
        return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
            !identifier.isEmpty && identifier.utf8.allSatisfy { byte in
                (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
                    || (byte >= Character("A").asciiValue! && byte <= Character("Z").asciiValue!)
                    || (byte >= Character("a").asciiValue! && byte <= Character("z").asciiValue!)
                    || byte == Character("-").asciiValue!
            }
        }
    }

    static func parseFeature(named name: String, from output: String) -> CodexFeatureState {
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard fields.first == name, fields.count >= 3 else { continue }
            guard let stage = recognizedFeatureStage(fields.dropFirst().dropLast()) else {
                continue
            }
            switch fields.last?.lowercased() {
            case "true": return .enabled(stage: stage)
            case "false": return .disabled(stage: stage)
            default: continue
            }
        }
        return .unknown
    }

    /// Codex owns this output, but it is rendered directly in TapQ's terminal diagnostics.
    /// Keep the accepted vocabulary closed so a malformed or hostile executable cannot relay
    /// control characters, bidi markers, or arbitrarily long stage labels to the terminal.
    private static func recognizedFeatureStage<C: Collection>(_ fields: C) -> String?
    where C.Element == String {
        switch Array(fields) {
        case ["stable"]:
            return "stable"
        case ["experimental"]:
            return "experimental"
        case ["under", "development"]:
            return "under development"
        case ["removed"]:
            return "removed"
        case ["deprecated"]:
            return "deprecated"
        default:
            return nil
        }
    }

    static func isBelowTestedLifecycleFloor(_ version: String) -> Bool? {
        compare(version, with: testedLifecycleFloor).map { $0 < 0 }
    }

    /// Semver-shaped comparison for Codex's numeric CLI releases. Unknown shapes stay unknown
    /// rather than being treated as incompatible. A prerelease of the exact floor is older than
    /// the stable floor; build metadata does not affect ordering.
    private static func compare(_ lhs: String, with rhs: String) -> Int? {
        guard let left = semanticVersion(lhs), let right = semanticVersion(rhs) else {
            return nil
        }
        let count = max(left.components.count, right.components.count)
        for index in 0..<count {
            let leftValue = index < left.components.count ? left.components[index] : 0
            let rightValue = index < right.components.count ? right.components[index] : 0
            if leftValue != rightValue { return leftValue < rightValue ? -1 : 1 }
        }
        if left.prerelease == right.prerelease { return 0 }
        if left.prerelease == nil { return 1 }
        if right.prerelease == nil { return -1 }
        return left.prerelease! < right.prerelease! ? -1 : 1
    }

    private static func semanticVersion(
        _ value: String
    ) -> (components: [Int], prerelease: String?)? {
        let withoutBuildMetadata = value.split(separator: "+", maxSplits: 1).first.map(String.init)
            ?? value
        let pieces = withoutBuildMetadata.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let numericText = pieces.first, !numericText.isEmpty else { return nil }
        let numeric = numericText.split(separator: ".", omittingEmptySubsequences: false)
        guard numeric.count >= 3 else { return nil }
        let components = numeric.compactMap { Int($0) }
        guard components.count == numeric.count else { return nil }
        let prerelease: String?
        if pieces.count == 2 {
            guard !pieces[1].isEmpty else { return nil }
            prerelease = String(pieces[1])
        } else {
            prerelease = nil
        }
        return (components, prerelease)
    }
}

struct ResolvedCodexCLIProcessRunner {
    let executableURL: URL
    let environment: [String: String]
    let currentDirectory: URL

    func run(arguments: [String]) -> CodexCLICommandResult {
        CodexCLIProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            timeout: CodexCLIProcessRunner.commandTimeout
        )
    }
}

enum CodexCLIProcessRunner {
    fileprivate static let commandTimeout: TimeInterval = 3
    private static let terminationGrace: TimeInterval = 0.5
    static let maximumCapturedOutputBytes = 1_048_576

    static func resolve(
        environment: [String: String],
        currentDirectory: URL
    ) -> ResolvedCodexCLIProcessRunner? {
        guard let executableURL = executableURL(
            environment: environment,
            currentDirectory: currentDirectory
        ) else {
            return nil
        }
        return ResolvedCodexCLIProcessRunner(
            executableURL: executableURL,
            environment: probeEnvironment(from: environment),
            currentDirectory: currentDirectory
        )
    }

    /// These diagnostics are fixed, local-only Codex commands. Pass only process-discovery,
    /// configuration-home, temporary-directory, and locale values they may need; unrelated
    /// credentials and application-specific state must not reach a PATH-resolved executable.
    static func probeEnvironment(from environment: [String: String]) -> [String: String] {
        let retainedKeys = [
            "PATH",
            "HOME",
            "CODEX_HOME",
            "XDG_CONFIG_HOME",
            "XDG_CACHE_HOME",
            "XDG_DATA_HOME",
            "TMPDIR",
            "TMP",
            "TEMP",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
        ]
        var result = environment.filter { retainedKeys.contains($0.key) }
        result["NO_COLOR"] = "1"
        result["TERM"] = "dumb"
        return result
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) -> CodexCLICommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let termination = DispatchSemaphore(value: 0)
        let drains = DispatchGroup()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            return .unavailable
        }

        let outputDrain = BoundedPipeDrain(
            handle: standardOutput.fileHandleForReading,
            retainedByteLimit: maximumCapturedOutputBytes,
            group: drains
        )
        let errorDrain = BoundedPipeDrain(
            handle: standardError.fileHandleForReading,
            retainedByteLimit: maximumCapturedOutputBytes,
            group: drains
        )
        let pipeDrains = [outputDrain, errorDrain]

        guard termination.wait(timeout: .now() + max(0, timeout)) == .success else {
            stop(process, termination: termination)
            finishDrains(pipeDrains, group: drains)
            return .unavailable
        }
        guard drains.wait(timeout: .now() + terminationGrace) == .success else {
            pipeDrains.forEach { $0.cancel() }
            _ = drains.wait(timeout: .now() + terminationGrace)
            return .unavailable
        }
        return .completed(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputDrain.data, as: UTF8.self),
            standardError: String(decoding: errorDrain.data, as: UTF8.self)
        )
    }

    private static func finishDrains(
        _ drains: [BoundedPipeDrain],
        group: DispatchGroup
    ) {
        if group.wait(timeout: .now() + terminationGrace) == .success { return }
        drains.forEach { $0.cancel() }
        _ = group.wait(timeout: .now() + terminationGrace)
    }

    private static func stop(_ process: Process, termination: DispatchSemaphore) {
        if process.isRunning { process.terminate() }
        if termination.wait(timeout: .now() + terminationGrace) == .success { return }
        if process.isRunning {
            POSIXProcessControl.forceTerminate(processIdentifier: process.processIdentifier)
        }
        _ = termination.wait(timeout: .now() + terminationGrace)
    }

    private static func executableURL(
        environment: [String: String],
        currentDirectory: URL
    ) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        for component in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = component.isEmpty
                ? currentDirectory
                : URL(fileURLWithPath: String(component), isDirectory: true)
            let candidate = directory.appendingPathComponent("codex").standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Event-driven pipe draining avoids tying up a global worker on a blocking read when a
/// descendant inherits the pipe after the direct child exits. Output beyond the retention cap
/// is still consumed so a noisy Codex process cannot deadlock on a full pipe.
private final class BoundedPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let retainedByteLimit: Int
    private let group: DispatchGroup
    private let cleanupQueue = DispatchQueue(label: "tapq.codex-cli-probe.pipe-cleanup")
    private let lock = NSLock()
    private var stored = Data()
    private var isFinished = false

    init(handle: FileHandle, retainedByteLimit: Int, group: DispatchGroup) {
        self.handle = handle
        self.retainedByteLimit = max(0, retainedByteLimit)
        self.group = group
        group.enter()
        handle.readabilityHandler = { [weak self] _ in
            self?.consumeAvailableData()
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func cancel() {
        let shouldFinish = markFinished()
        if shouldFinish { scheduleCleanup() }
    }

    private func consumeAvailableData() {
        var shouldFinish = false
        lock.lock()
        if !isFinished {
            let chunk = handle.availableData
            if chunk.isEmpty {
                isFinished = true
                shouldFinish = true
            } else if stored.count < retainedByteLimit {
                stored.append(chunk.prefix(retainedByteLimit - stored.count))
            }
        }
        lock.unlock()
        if shouldFinish { scheduleCleanup() }
    }

    private func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        return true
    }

    private func scheduleCleanup() {
        cleanupQueue.async { [self] in
            // swift-corelibs-foundation closes FileHandle by synchronizing with its monitoring
            // queue. Closing from that queue's callback traps in libdispatch, so tear down here.
            handle.readabilityHandler = nil
            try? handle.close()
            group.leave()
        }
    }
}
