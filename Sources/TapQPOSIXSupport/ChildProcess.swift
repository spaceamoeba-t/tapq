import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ChildProcessError: Error, Equatable, CustomStringConvertible {
    case spawnFailed(String)
    /// Every slot of the `killAllGroups` registry is taken.
    case tooManyChildren
    /// `write(line:)` after the input closed: by `closeInput()`, a failed write, or the exit.
    case inputClosed(String)

    public var description: String {
        switch self {
        case .spawnFailed(let detail): return "could not spawn: \(detail)"
        case .tooManyChildren: return "too many live child processes"
        case .inputClosed(let reason): return "the child's input is closed: \(reason)"
        }
    }
}

/// A delegate CLI as a child process in its own process group.
///
/// Four threads per child: a reader per output pipe, a serial writer for stdin (so a large
/// line never blocks the caller, 02-13), and a waiter. `.exited` is yielded by whichever of
/// them finishes last, so it always follows the child's last stdout and stderr line (02-10).
///
/// When the leader exits, the waiter SIGKILLs the rest of its group before reaping it. The
/// unreaped leader keeps the group id reserved, so the signal cannot reach a recycled group,
/// and no grandchild survives holding a pipe open, which would hold `.exited` back.
public final class ChildProcess: LineChannel, @unchecked Sendable {
    /// The child's pid, which is also its process group id.
    public let processGroup: pid_t
    public let signals: AsyncStream<ChannelSignal>

    private let continuation: AsyncStream<ChannelSignal>.Continuation
    /// Guards every `var` below; the writer waits on it for lines.
    private let condition = NSCondition()
    private var pendingLines: [Data] = []
    private var inputClosedReason: String?
    private var openReaders = 2
    private var exitCode: Int32?
    private var exitReported = false
    private var exitWaiters: [ExitWaiter] = []

    /// posix_spawn with POSIX_SPAWN_SETPGROUP (pgid = pid). SIGPIPE, SIGINT and SIGTERM are
    /// reset to their defaults in the child: the kernel ignores all three, and an ignored
    /// disposition would survive `exec` and make the D13 SIGTERM a no-op.
    public init(executable: String, arguments: [String], environment: [String: String],
                workingDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ChildProcessError.spawnFailed("\(workingDirectory.path) is not a directory")
        }
        guard access(executable, X_OK) == 0 else {
            throw ChildProcessError.spawnFailed("\(executable) is not executable: \(Self.errorText(errno))")
        }
        let child = try Self.launch(Self.trampoline + [workingDirectory.path, executable] + arguments,
                                    environment: environment)
        processGroup = child.pid
        let (stream, continuation) = AsyncStream<ChannelSignal>.makeStream()
        signals = stream
        self.continuation = continuation

        Self.start("stdout") { [self] in pump(child.output) { .stdout($0) } }
        Self.start("stderr") { [self] in pump(child.errors) { .stderr($0) } }
        Self.start("stdin") { [self] in drain(into: child.input) }
        Self.start("wait") { [self] in awaitExit() }
    }

    public func write(line: String) throws {
        condition.lock()
        defer { condition.unlock() }
        if let reason = inputClosedReason { throw ChildProcessError.inputClosed(reason) }
        pendingLines.append(Data((line + "\n").utf8))
        condition.broadcast()
    }

    /// Lines already written still go out; then stdin closes.
    public func closeInput() {
        condition.lock()
        closeInputLocked("closed by TapQ")
        condition.unlock()
    }

    /// D13: close stdin, wait for the exit up to `grace`, SIGTERM the group, wait up to
    /// `killAfter`, SIGKILL the group. Returns once the leader exited or SIGKILL was sent.
    public func terminate(grace: Duration, killAfter: Duration) async {
        closeInput()
        if await leaderExit(within: grace) { return }
        signalGroup(SIGTERM)
        if await leaderExit(within: killAfter) { return }
        signalGroup(SIGKILL)
    }

    /// For a child that stops on a signal, not at its stdin's end (a recorder whose stdin is
    /// a terminal's when a person runs it): `signal` to the leader alone, so it
    /// stops in order and stops what it started itself; SIGKILL to the group only if it outlives
    /// `grace`. A second signal would be ignored, so there is none. Returns once the leader
    /// exited or SIGKILL was sent.
    public func stop(signal: Int32, grace: Duration) async {
        signalLeader(signal)
        if await leaderExit(within: grace) { return }
        signalGroup(SIGKILL)
    }

    /// Every live group, for the fatal path: `ProcessFatal` calls this before exit(70).
    /// killpg(SIGKILL) over a fixed slot list, with no lock, no allocation and no lazy
    /// initialization, so it is async-signal-safe from process start.
    public static func killAllGroups() {
        killAll(in: &groups)
    }

    private static func killAll(in storage: UnsafeMutableRawPointer) {
        let slots = storage.assumingMemoryBound(to: pid_t.self)
        var slot = 0
        while slot < groupCapacity {
            // Read once: a slot cleared between two reads would make this killpg(0), which
            // is TapQ's own group.
            let group = slots[slot]
            if group > 0 { killpg(group, SIGKILL) }
            slot += 1
        }
    }

    // MARK: - Spawning

    /// `posix_spawn` has no working-directory action that every libc Swift imports exposes
    /// (`…_addchdir_np` is a GNU extension), so the child starts as `/bin/sh`, changes
    /// directory and `exec`s the executable in place: same pid, same group, same pipes.
    private static let trampoline = ["/bin/sh", "-c", #"cd "$1" && shift && exec "$@""#, "tapq-spawn"]

    /// Held from the first pipe to the spawn, so no other `ChildProcess` spawn inherits a
    /// pipe end, including in the moment between `pipe` and `fcntl`. (`pipe2` would close
    /// that gap atomically, but Swift's Glibc module does not export it.)
    private static let spawnLock = NSLock()

    private static func launch(_ argv: [String], environment: [String: String])
        throws -> (pid: pid_t, input: Int32, output: Int32, errors: Int32) {
        spawnLock.lock()
        defer { spawnLock.unlock() }
        var descriptors: [Int32] = []
        for _ in 0..<3 {
            var pair: [Int32] = [0, 0]
            let created = pipe(&pair) == 0
            if created { for descriptor in pair { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) } }
            guard created else {
                let failure = errno
                descriptors.forEach { _ = close($0) }
                throw ChildProcessError.spawnFailed("pipe: \(errorText(failure))")
            }
            descriptors += pair
        }
        // [stdin read, stdin write, stdout read, stdout write, stderr read, stderr write]
        let (pid, status) = spawn(argv, environment: environment,
                                  stdin: descriptors[0], stdout: descriptors[3], stderr: descriptors[5])
        for child in [descriptors[0], descriptors[3], descriptors[5]] { _ = close(child) }
        let parent = (input: descriptors[1], output: descriptors[2], errors: descriptors[4])
        guard status == 0 else {
            for descriptor in [parent.input, parent.output, parent.errors] { _ = close(descriptor) }
            throw ChildProcessError.spawnFailed("\(argv.joined(separator: " ")): \(errorText(status))")
        }
        guard register(pid) else {
            killpg(pid, SIGKILL)
            var reaped: Int32 = 0
            _ = waitpid(pid, &reaped, 0)
            for descriptor in [parent.input, parent.output, parent.errors] { _ = close(descriptor) }
            throw ChildProcessError.tooManyChildren
        }
        // A write to a dead child must fail with EPIPE, not kill TapQ. Darwin can say so per
        // descriptor; elsewhere it rests on SIGPIPE being ignored process-wide (`LineChannel`).
        #if canImport(Darwin)
        _ = fcntl(parent.input, F_SETNOSIGPIPE, 1)
        #endif
        return (pid, parent.input, parent.output, parent.errors)
    }

    private static func spawn(_ argv: [String], environment: [String: String],
                              stdin: Int32, stdout: Int32, stderr: Int32) -> (pid_t, Int32) {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        var flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        #if canImport(Darwin)
        // Only the three descriptors mapped above reach the child, whatever else is open.
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        let cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnvironment: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArguments + cEnvironment).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, argv[0], &actions, &attributes, cArguments, cEnvironment)
        return (pid, status)
    }

    private static func start(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "tapq.child.\(name)"
        thread.start()
    }

    // MARK: - Threads

    private func pump(_ descriptor: Int32, as signal: (String) -> ChannelSignal) {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                for line in framer.push(Data(buffer[0..<count])) { continuation.yield(signal(line)) }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        if let last = framer.flush() { continuation.yield(signal(last)) }
        _ = close(descriptor)
        condition.lock()
        openReaders -= 1
        let code = takeExitLocked()
        condition.unlock()
        report(code)
    }

    private func drain(into descriptor: Int32) {
        while let line = nextLine() {
            if let failure = Self.writeAll(line, to: descriptor) {
                condition.lock()
                closeInputLocked("write failed: \(Self.errorText(failure))")
                pendingLines.removeAll()
                condition.unlock()
                break
            }
        }
        _ = close(descriptor)
    }

    /// The next line to write; nil once the input is closed and every pending line is out.
    private func nextLine() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while pendingLines.isEmpty, inputClosedReason == nil { condition.wait() }
        return pendingLines.isEmpty ? nil : pendingLines.removeFirst()
    }

    private func awaitExit() {
        var info = siginfo_t()
        while waitid(P_PID, id_t(processGroup), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        killpg(processGroup, SIGKILL)
        Self.unregister(processGroup)

        condition.lock()
        var status: Int32 = 0
        while waitpid(processGroup, &status, 0) == -1, errno == EINTR {}
        let signal = status & 0x7f
        // The shell's convention: a signal death reads as 128 + the signal (SIGKILL → 137).
        exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        closeInputLocked("the child exited")
        let waiters = exitWaiters
        exitWaiters = []
        let code = takeExitLocked()
        condition.unlock()
        waiters.forEach { $0.resume(exited: true) }
        report(code)
    }

    // MARK: - State

    private func closeInputLocked(_ reason: String) {
        guard inputClosedReason == nil else { return }
        inputClosedReason = reason
        condition.broadcast()
    }

    /// The exit code, exactly once, when both readers are at EOF and the leader is reaped.
    private func takeExitLocked() -> Int32? {
        guard openReaders == 0, let exitCode, !exitReported else { return nil }
        exitReported = true
        return exitCode
    }

    private func report(_ code: Int32?) {
        guard let code else { return }
        continuation.yield(.exited(code))
        continuation.finish()
    }

    /// Signals the group only while the leader is unreaped, so the group id is still ours.
    private func signalGroup(_ signal: Int32) {
        condition.lock()
        defer { condition.unlock() }
        if exitCode == nil { killpg(processGroup, signal) }
    }

    /// The leader alone, likewise only while it is unreaped, so the pid is still ours.
    private func signalLeader(_ signal: Int32) {
        condition.lock()
        defer { condition.unlock() }
        if exitCode == nil { kill(processGroup, signal) }
    }

    private func leaderExit(within limit: Duration) async -> Bool {
        let waiter = ExitWaiter()
        return await withCheckedContinuation { continuation in
            waiter.arm(continuation, timeout: limit)
            condition.lock()
            let exited = exitCode != nil
            if !exited { exitWaiters.append(waiter) }
            condition.unlock()
            if exited { waiter.resume(exited: true) }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
        data.withUnsafeBytes { bytes -> Int32? in
            var offset = 0
            while offset < bytes.count {
                let written = systemWrite(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written >= 0 {
                    offset += written
                } else if errno != EINTR {
                    return errno
                }
            }
            return nil
        }
    }

    private static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    // MARK: - Registry

    private static let groupCapacity = 16
    /// A zero literal, so the slots live in the binary's data: nothing initializes them
    /// lazily, and `@exclusivity(unchecked)` leaves no access check for a signal handler to
    /// run into. Written under `registryLock`; read by `killAllGroups` without it.
    @exclusivity(unchecked)
    private nonisolated(unsafe) static var groups: (pid_t, pid_t, pid_t, pid_t, pid_t, pid_t, pid_t, pid_t,
                                                    pid_t, pid_t, pid_t, pid_t, pid_t, pid_t, pid_t, pid_t)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    private static let registryLock = NSLock()

    private static func register(_ group: pid_t) -> Bool {
        guard group > 0 else { return false }
        registryLock.lock()
        defer { registryLock.unlock() }
        return replace(0, with: group, in: &groups)
    }

    private static func unregister(_ group: pid_t) {
        registryLock.lock()
        defer { registryLock.unlock() }
        _ = replace(group, with: 0, in: &groups)
    }

    /// Sets the first slot holding `old` to `new`; false when no slot holds `old`.
    private static func replace(_ old: pid_t, with new: pid_t, in storage: UnsafeMutableRawPointer) -> Bool {
        let slots = storage.assumingMemoryBound(to: pid_t.self)
        guard let slot = (0..<groupCapacity).first(where: { slots[$0] == old }) else { return false }
        slots[slot] = new
        return true
    }
}

/// One bounded wait in `terminate`: resumed once, by the exit or by the timeout.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    func arm(_ continuation: CheckedContinuation<Bool, Never>, timeout: Duration) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        let timer = Task { [self] in
            try? await Task.sleep(for: timeout)
            resume(exited: false)
        }
        lock.lock()
        if self.continuation == nil { timer.cancel() } else { self.timer = timer }
        lock.unlock()
    }

    func resume(exited: Bool) {
        lock.lock()
        let continuation = self.continuation
        let timer = self.timer
        self.continuation = nil
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: exited)
    }
}

/// `write(2)`, named apart from `LineChannel.write(line:)`, which shadows it inside the class.
private func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, bytes, count)
    #else
    Glibc.write(descriptor, bytes, count)
    #endif
}
