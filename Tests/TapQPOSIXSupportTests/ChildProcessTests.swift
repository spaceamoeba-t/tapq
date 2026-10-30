import Foundation
import XCTest
import TapQPOSIXSupport
#if canImport(Glibc)
import Glibc
#endif

/// `ChildProcess` against `/bin/sh` scripts: the one portable suite that spawns. Every wait
/// is on a signal the child produced, bounded so a regression fails instead of hanging.
final class ChildProcessTests: XCTestCase {
    private let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    override func setUp() {
        super.setUp()
        #if !canImport(Darwin)
        // What tapq-kernel's main does (the `LineChannel` contract). Darwin needs nothing:
        // the stdin write end carries F_SETNOSIGPIPE, and the write tests below prove it.
        signal(SIGPIPE, SIG_IGN)
        #endif
    }

    /// Leaves nothing running when an assertion failed before a child exited.
    override func tearDown() {
        ChildProcess.killAllGroups()
        super.tearDown()
    }

    func testJSONLinesSurviveAnyChunkingAndTheExitCodeIsReported() async throws {
        // Far more than a pipe buffer, so reads split lines at arbitrary points.
        let script = #"""
            printf '{"a":'; printf '1}\n{"b"'; printf ':2}\n'
            printf '{"big":"'; head -c 200000 /dev/zero | tr '\0' x; printf '"}\n'
            printf 'tail'
            exit 3
            """#
        let reader = try spawn(script)
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(lines(signals, stdout: true).prefix(2), [##"{"a":1}"##, ##"{"b":2}"##])
        XCTAssertEqual(lines(signals, stdout: true).dropFirst(2).first,
                       ##"{"big":""## + String(repeating: "x", count: 200_000) + ##""}"##)
        XCTAssertEqual(lines(signals, stdout: true).last, "tail")
        XCTAssertEqual(signals.last, .exited(3))
    }

    /// 02-10: the exit is reported only after both pipes reached EOF.
    func testStderrWrittenBeforeExitArrivesInFullBeforeExited() async throws {
        let reader = try spawn(#"i=0; while [ $i -lt 200 ]; do echo "line $i" >&2; i=$((i+1)); done; exit 1"#)
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(lines(signals, stdout: false), (0..<200).map { "line \($0)" })
        XCTAssertEqual(signals.last, .exited(1))
        XCTAssertEqual(signals.filter(isExit).count, 1)
    }

    func testTheChildRunsInItsWorkingDirectoryWithExactlyTheGivenEnvironment() async throws {
        let reader = try spawn(#"pwd -P; echo "$TAPQ_PROBE"; echo "${HOME:-unset}""#,
                               environment: ["TAPQ_PROBE": "a b"],
                               workingDirectory: URL(fileURLWithPath: "/"))
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(lines(signals, stdout: true), ["/", "a b", "unset"])
    }

    func testLinesWrittenBeforeCloseInputAreDeliveredThenTheChildSeesEOF() async throws {
        let reader = try spawn(#"while read -r line; do echo "got $line"; done; echo eof"#)
        try reader.child.write(line: "one")
        try reader.child.write(line: "two")
        reader.child.closeInput()
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(lines(signals, stdout: true), ["got one", "got two", "eof"])
        XCTAssertEqual(signals.last, .exited(0))
    }

    /// D13: a child that exits on stdin EOF never sees a signal.
    func testTerminateReturnsAsSoonAsAnEOFExitingChildIsGone() async throws {
        let reader = try spawn(#"cat >/dev/null; exit 4"#)
        await reader.child.terminate(grace: .seconds(10), killAfter: .seconds(1))
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(signals.last, .exited(4))
    }

    func testAChildThatIgnoresSIGTERMIsKilled() async throws {
        // An ignored signal stays ignored across exec, so `sleep` ignores SIGTERM too.
        let reader = try spawn(#"trap '' TERM; echo ready; exec sleep 30"#)
        _ = try await reader.read(until: { $0 == .stdout("ready") })
        await reader.child.terminate(grace: .milliseconds(100), killAfter: .milliseconds(100))
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(signals.last, .exited(128 + SIGKILL))
    }

    /// A child that stops on a signal (a recording): the signal reaches the leader, which stops
    /// in its own time; its stdin's end means nothing to it.
    func testStopSignalsTheLeaderAndWaitsForItToStopInOrder() async throws {
        let reader = try spawn(#"trap 'echo stopping; exit 0' INT; echo ready; while :; do sleep 0.05; done"#)
        _ = try await reader.read(until: { $0 == .stdout("ready") })
        await reader.child.stop(signal: SIGINT, grace: .seconds(10))
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(lines(signals, stdout: true).last, "stopping")
        XCTAssertEqual(signals.last, .exited(0))
    }

    /// One that does not stop is killed with its group once the grace is out: no second signal.
    func testAChildThatOutlivesItsStopIsKilled() async throws {
        let reader = try spawn(#"trap '' INT; echo ready; exec sleep 30"#)
        _ = try await reader.read(until: { $0 == .stdout("ready") })
        await reader.child.stop(signal: SIGINT, grace: .milliseconds(100))
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(signals.last, .exited(128 + SIGKILL))
    }

    /// The grandchild holds the stdout pipe, so `.exited` (which waits for EOF) can only
    /// arrive once the grandchild is dead too.
    func testAGrandchildDiesWithTheGroup() async throws {
        let reader = try spawn(#"sleep 30 & echo ready; wait"#)
        _ = try await reader.read(until: { $0 == .stdout("ready") })
        await reader.child.terminate(grace: .milliseconds(100), killAfter: .seconds(5))
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(signals.last, .exited(128 + SIGTERM))
    }

    /// When the leader exits on its own, what is left of its group goes with it.
    func testAGrandchildLeftBehindByAnExitingLeaderIsKilled() async throws {
        let reader = try spawn(#"sleep 30 & exit 0"#)
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(signals.last, .exited(0))
    }

    func testAWriteAfterTheChildDiedThrows() async throws {
        let reader = try spawn("exit 0")
        _ = try await reader.read(until: isExit)
        XCTAssertThrowsError(try reader.child.write(line: "late")) { error in
            XCTAssertEqual(error as? ChildProcessError, .inputClosed("the child exited"))
        }
    }

    /// A child that closed its stdin: the write fails with EPIPE on the writer thread
    /// instead of raising SIGPIPE in this process, and later writes throw.
    func testAWriteToAClosedPipeDoesNotKillTheParent() async throws {
        let reader = try spawn(#"exec 0<&-; echo closed; exec sleep 30"#)
        _ = try await reader.read(until: { $0 == .stdout("closed") })
        try reader.child.write(line: String(repeating: "y", count: 100_000))
        await reader.child.terminate(grace: .milliseconds(100), killAfter: .seconds(5))
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(signals.last, .exited(128 + SIGTERM))
        XCTAssertThrowsError(try reader.child.write(line: "late"))
    }

    func testKillAllGroupsKillsALiveGroup() async throws {
        let reader = try spawn(#"trap '' TERM; echo ready; exec sleep 30"#)
        _ = try await reader.read(until: { $0 == .stdout("ready") })
        ChildProcess.killAllGroups()
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(signals.last, .exited(128 + SIGKILL))
    }

    /// The working-directory trampoline `exec`s in place: the pid that runs the script is
    /// the one spawned, and it leads a group that is not TapQ's.
    func testTheSpawnedPidRunsTheExecutableAndLeadsItsOwnGroup() async throws {
        let reader = try spawn(#"echo $$"#)
        let signals = try await reader.read(until: isExit)
        XCTAssertEqual(lines(signals, stdout: true), ["\(reader.child.processGroup)"])
        XCTAssertNotEqual(reader.child.processGroup, getpgrp())
    }

    /// No descriptor of TapQ's reaches a child: not another live child's pipes (they are
    /// close-on-exec), and on Darwin not even one TapQ left inheritable
    /// (POSIX_SPAWN_CLOEXEC_DEFAULT). The `pipe`/`fcntl` race itself is not unit-testable.
    func testAChildInheritsNoOtherDescriptor() async throws {
        // Inheritable, and numbered above anything the shell opens for itself.
        let null = open("/dev/null", O_RDONLY)
        let stray = fcntl(null, F_DUPFD, 60)
        close(null)
        defer { close(stray) }
        let alone = try await descriptorsOfAChild()
        let sibling = try spawn("echo ready; exec sleep 30")
        _ = try await sibling.read(until: { $0 == .stdout("ready") })

        let besideASibling = try await descriptorsOfAChild()
        XCTAssertEqual(besideASibling, alone)
        #if canImport(Darwin)
        XCTAssertLessThan(stray, 64, "the child only looks below 64")
        XCTAssertFalse(alone.contains("\(stray)"), "\(alone)")
        #endif
    }

    func testAMissingExecutableOrDirectoryThrowsAtSpawn() {
        XCTAssertThrowsError(try ChildProcess(executable: "/tapq/no/such/binary", arguments: [],
                                              environment: [:], workingDirectory: temporary))
        XCTAssertThrowsError(try ChildProcess(executable: "/bin/sh", arguments: [],
                                              environment: [:],
                                              workingDirectory: URL(fileURLWithPath: "/tapq/no/such/dir")))
    }

    // MARK: - Helpers

    private func spawn(_ script: String,
                       environment: [String: String] = [:],
                       workingDirectory: URL? = nil) throws -> SignalReader {
        let child = try ChildProcess(executable: "/bin/sh",
                                     arguments: ["-c", script],
                                     environment: environment,
                                     workingDirectory: workingDirectory ?? temporary)
        return SignalReader(child)
    }

    private func descriptorsOfAChild() async throws -> [String] {
        // A subshell's `<&n` fails exactly when n is not open; the shell opens nothing itself.
        let reader = try spawn(#"n=0; while [ $n -lt 64 ]; do (: <&$n) 2>/dev/null && echo $n; n=$((n+1)); done"#)
        return lines(try await reader.read(until: isExit), stdout: true)
    }

    private func lines(_ signals: [ChannelSignal], stdout: Bool) -> [String] {
        signals.compactMap { signal in
            switch signal {
            case .stdout(let line) where stdout: return line
            case .stderr(let line) where !stdout: return line
            default: return nil
            }
        }
    }
}

private let isExit: @Sendable (ChannelSignal) -> Bool = { signal in
    if case .exited = signal { return true }
    return false
}

private struct TimedOut: Error {}

/// One consumer of a child's signals across several waits.
private final class SignalReader: @unchecked Sendable {
    let child: ChildProcess
    private var iterator: AsyncStream<ChannelSignal>.AsyncIterator

    init(_ child: ChildProcess) {
        self.child = child
        iterator = child.signals.makeAsyncIterator()
    }

    /// Every signal up to and including the first that satisfies `stop`. Throws when the
    /// stream ends first or `bound` passes.
    func read(until stop: @escaping @Sendable (ChannelSignal) -> Bool,
              bound: Duration = .seconds(10)) async throws -> [ChannelSignal] {
        try await withThrowingTaskGroup(of: [ChannelSignal].self) { group in
            group.addTask { try await self.collect(until: stop) }
            group.addTask {
                try await Task.sleep(for: bound)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    private func collect(until stop: (ChannelSignal) -> Bool) async throws -> [ChannelSignal] {
        var received: [ChannelSignal] = []
        while let signal = await iterator.next() {
            received.append(signal)
            if stop(signal) { return received }
        }
        throw TimedOut()
    }
}
