import Foundation
import TapQContracts
import TapQPOSIXSupport

/// Everything needed to start one owned agent session, as a value.
///
/// A value rather than a call so the decision and the act are separable: the launcher
/// composes this, a test asserts on it field by field, and only then does a runner turn it
/// into a process. Every spawn TapQ performs is inspectable before it happens.
public struct OwnedSessionSpawn: Sendable, Equatable {
    /// Absolute path to the agent CLI. Resolved by the caller, never a bare name — a name
    /// would be resolved again by the process machinery against an environment TapQ has
    /// already decided about.
    public let executablePath: String
    /// The argument vector, in order, excluding `argv[0]`.
    public let arguments: [String]
    /// The child's environment. It is the runtime's own, deliberately: the spawned session's
    /// hooks find *this* broker through `TAPQ_BROKER_DIR`, and the agent finds its
    /// credentials the same way it would from the wearer's own shell.
    public let environment: [String: String]
    /// Where the session works. The composition's, never inferred here.
    public let workingDirectoryPath: String

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectoryPath: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryPath = workingDirectoryPath
    }
}

/// Whether a spawn produced a child.
public enum OwnedSessionSpawnOutcome: Sendable, Equatable {
    case launched(processIdentifier: Int32)
    case failed
}

/// The process boundary, injected so every path above it is testable without starting a real
/// agent.
///
/// Three verbs and no more. There is nothing here that reads a child's output or writes to
/// its input: an owned session speaks to TapQ through the broker, like every other session,
/// and a second channel into the same conversation would be a second thing to keep honest.
///
/// ``terminate(processIdentifier:)`` is required to be a no-op for any identifier this runner
/// did not itself launch. That is the lowest place the "own children only" rule can be
/// enforced, and it is enforced there so that no bug above it can turn into a signal sent to
/// a session the wearer started at their keyboard.
public protocol OwnedSessionProcessRunning: Sendable {
    func launch(_ spawn: OwnedSessionSpawn) -> OwnedSessionSpawnOutcome
    /// Whether a child this runner launched is still running. `false` for anything else.
    func isRunning(processIdentifier: Int32) -> Bool
    /// Stops a child this runner launched, gracefully if it will go. Ignores anything else.
    func terminate(processIdentifier: Int32)
}

/// The real runner: `Foundation.Process`, plus the table that makes "own children only"
/// checkable rather than merely intended.
///
/// The child's standard streams all go to the null device. That is not thrift: an owned
/// session is long-lived, and a pipe nobody drains fills and stops the agent mid-turn, which
/// would present as a session that mysteriously hangs. What the session produces reaches
/// TapQ the way every session's work reaches it — hook traffic on the broker and the
/// transcript on disk — and its stdin is closed because a headless session is not typed into.
public final class POSIXOwnedSessionProcessRunner: OwnedSessionProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    /// The children this runner started, by process identifier. The whole of the ownership
    /// claim: a pid absent from here is, as far as this type is concerned, somebody else's.
    private var children: [Int32: Process] = [:]
    private let terminationGrace: TimeInterval

    public init(terminationGrace: TimeInterval = OwnedSessionBudget.terminationGrace) {
        self.terminationGrace = terminationGrace
    }

    public func launch(_ spawn: OwnedSessionSpawn) -> OwnedSessionSpawnOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spawn.executablePath)
        process.arguments = spawn.arguments
        process.environment = spawn.environment
        process.currentDirectoryURL = URL(
            fileURLWithPath: spawn.workingDirectoryPath, isDirectory: true
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed
        }
        let identifier = process.processIdentifier
        lock.lock()
        children[identifier] = process
        lock.unlock()
        return .launched(processIdentifier: identifier)
    }

    public func isRunning(processIdentifier: Int32) -> Bool {
        lock.lock()
        let process = children[processIdentifier]
        lock.unlock()
        return process?.isRunning ?? false
    }

    public func terminate(processIdentifier: Int32) {
        lock.lock()
        let process = children.removeValue(forKey: processIdentifier)
        lock.unlock()
        guard let process, process.isRunning else { return }

        process.terminate()
        let deadline = Date().addingTimeInterval(max(0, terminationGrace))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else { return }
        POSIXProcessControl.forceTerminate(processIdentifier: processIdentifier)
    }

    /// The absolute path of `name` on `PATH`, or `nil`.
    ///
    /// The same scan `CodexCLIProcessRunner` performs, and for the same reason: TapQ decides
    /// which executable it is starting, once, from an environment it can see — rather than
    /// handing a bare name to the process machinery and finding out afterwards.
    public static func resolveExecutable(
        named name: String,
        environment: [String: String],
        workingDirectoryPath: String
    ) -> String? {
        guard let path = environment["PATH"] else { return nil }
        for component in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = component.isEmpty
                ? URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
                : URL(fileURLWithPath: String(component), isDirectory: true)
            let candidate = directory.appendingPathComponent(name).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
