import Foundation
import TapQContracts
import TapQPOSIXSupport

// `OwnedSessionSpawn`, `OwnedSessionSpawnOutcome`, and `OwnedSessionProcessRunning` live in
// `TapQContracts/OwnedSessionProcess.swift` since 2026-09-04, when the Codex launcher needed
// the same seam. The real runner stays here.

/// The real runner: `Foundation.Process`, plus the table that makes "own children only"
/// checkable rather than merely intended.
///
/// The child's standard streams all go to the null device. That is not thrift: an owned
/// session is long-lived, and a pipe nobody drains fills and stops the agent mid-turn, which
/// would present as a session that mysteriously hangs. What the session produces reaches
/// TapQ the way every session's work reaches it — hook traffic on the broker and the
/// transcript on disk — and its stdin is closed because a headless session is not typed into.
///
/// The one exception is the reading launch, for an agent that names its own session on
/// stdout: the pipe is drained on a background thread for as long as the child writes, so
/// the reason for the rule above — a full pipe — cannot occur, and the launcher stops
/// listening whenever it likes without the runner stopping draining.
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
        launch(spawn, standardOutput: nil)
    }

    public func launch(
        _ spawn: OwnedSessionSpawn,
        standardOutput: @escaping @Sendable (String) -> Void
    ) -> OwnedSessionSpawnOutcome {
        launch(spawn, standardOutput: Optional(standardOutput))
    }

    private func launch(
        _ spawn: OwnedSessionSpawn,
        standardOutput: (@Sendable (String) -> Void)?
    ) -> OwnedSessionSpawnOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spawn.executablePath)
        process.arguments = spawn.arguments
        process.environment = spawn.environment
        process.currentDirectoryURL = URL(
            fileURLWithPath: spawn.workingDirectoryPath, isDirectory: true
        )
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe: Pipe?
        if let standardOutput {
            let reading = Pipe()
            process.standardOutput = reading
            pipe = reading
            Self.drain(reading.fileHandleForReading, line: standardOutput)
        } else {
            process.standardOutput = FileHandle.nullDevice
            pipe = nil
        }

        do {
            try process.run()
        } catch {
            pipe?.fileHandleForReading.readabilityHandler = nil
            return .failed
        }
        let identifier = process.processIdentifier
        lock.lock()
        children[identifier] = process
        lock.unlock()
        return .launched(processIdentifier: identifier)
    }

    /// Reads `handle` to EOF on its own thread, handing over one line at a time. Bytes
    /// that are not a whole line yet are kept for the next read; a final unterminated line
    /// is delivered at EOF. Nothing is retained beyond one line, and a line that is not
    /// UTF-8 is dropped rather than decoded lossily.
    private static func drain(_ handle: FileHandle, line: @escaping @Sendable (String) -> Void) {
        let thread = Thread {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let text = String(data: lineData, encoding: .utf8) { line(text) }
                }
            }
            if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) { line(text) }
            try? handle.close()
        }
        thread.name = "tapq.owned-session.stdout"
        thread.start()
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

    /// The absolute path of `name` on `PATH`, or `nil`. See
    /// ``TapQContracts/OwnedSessionExecutable/resolve(named:environment:workingDirectoryPath:)``.
    public static func resolveExecutable(
        named name: String,
        environment: [String: String],
        workingDirectoryPath: String
    ) -> String? {
        OwnedSessionExecutable.resolve(
            named: name, environment: environment, workingDirectoryPath: workingDirectoryPath
        )
    }
}
