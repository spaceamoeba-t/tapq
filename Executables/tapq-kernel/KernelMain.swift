import Foundation
import TapQContracts
import TapQKernel
import TapQKernelClaude
import TapQPOSIXSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `tapq-kernel`. Exit 0 is a clean stop, 64 a usage refusal (nothing has started), 70 a
/// fatal or a startup refusal (one `tapq-kernel: fatal in …` line on stderr, through
/// `ProcessFatal`).
@main
struct KernelMain {
    @MainActor
    static func main() async {
        // First: a write to a dead delegate's pipe must be an EPIPE error, never a signal.
        signal(SIGPIPE, SIG_IGN)

        let invocation: KernelCommandLine.Invocation
        do {
            invocation = try KernelCommandLine.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            refuse(error)
        }
        let environment = ProcessInfo.processInfo.environment
        let support = KernelPaths.defaultSupportDirectory(environment: environment)

        switch invocation {
        case .help:
            print(KernelCommandLine.usage)
            exit(0)
        case .clear(let workspace):
            clear(workspace, supportDirectory: support)
        case .run(let options):
            // The kernel parses the chat agents' flags; this build links no chat agent.
            if !options.desktopChats.isEmpty { refuse(UnavailableFlag(flag: "--desktop-chat")) }
            if !options.apiChats.isEmpty { refuse(UnavailableFlag(flag: "--api-chat")) }
            #if canImport(TapQAudioIO)
            await run(options, supportDirectory: support, environment: environment)
            #else
            // The microphone and the speaker are Apple adapters; there is no kernel without them.
            _ = options
            ProcessFatal().crash(FatalReason(subsystem: "startup",
                                             reason: "tapq-kernel runs on macOS only"))
            #endif
        }
    }

    // MARK: - clear

    /// Deletes what TapQ kept for the workspace. Its fatal writes no diagnostics file: that
    /// would land in the directory being deleted.
    @MainActor
    private static func clear(_ workspace: URL, supportDirectory: URL) -> Never {
        let fatal = ProcessFatal()
        let directory = KernelPaths.directory(supportDirectory: supportDirectory,
                                              workspace: workspace)
        do {
            if FileManager.default.fileExists(atPath: directory.path),
               try !KernelWorkspaceLock.acquire(in: directory) {
                fatal.crash(FatalReason(subsystem: "clear",
                                        reason: "TapQ is running for this workspace; stop it first"))
            }
            try KernelWorkspacePreparation.clear(workspace: workspace,
                                                 supportDirectory: supportDirectory)
        } catch {
            crash(error, fatal: fatal)
        }
        exit(0)
    }

    // MARK: - run

    #if canImport(TapQAudioIO)
    @MainActor
    private static func run(_ options: KernelCommandLine,
                            supportDirectory: URL,
                            environment: [String: String]) async -> Never {
        // Judged by the Claude adapter's own type, the one list of modes; a refusal is usage.
        let permissionMode: ClaudePermissionMode
        let directory: URL
        do {
            permissionMode = try options.permissionMode.map(ClaudePermissionMode.parse)
                ?? (options.autoMode ? .auto : .standard)
            if options.autoMode, permissionMode != .auto {
                throw KernelUsageError.autoModeWithPermissionMode(permissionMode.rawValue)
            }
            directory = try KernelWorkspacePreparation.prepare(options,
                                                               supportDirectory: supportDirectory)
        } catch {
            refuse(error)
        }

        // From here there is somewhere to write, so from here nothing is a usage refusal.
        let sink = KernelFanOutDiagnosticSink(sinks: [
            AppendingFileDiagnosticSink(
                path: directory.appendingPathComponent(KernelStartup.diagnosticsFileName).path),
            KernelConsoleDiagnosticSink(environment: environment),
        ])
        // Before the version probes and the speech handshake, which can take seconds each.
        KernelShutdownSignals.install(sink: sink)
        let fatal = ProcessFatal(diagnostics: sink, beforeExit: { ChildProcess.killAllGroups() })
        let startup: KernelStartup.Checked
        do {
            guard try KernelWorkspaceLock.acquire(in: directory) else {
                throw KernelStartupFailure(subsystem: "startup",
                                           reason: "TapQ is already running for this workspace")
            }
            startup = try await KernelStartup.check(
                workspace: options.workspace,
                environment: environment,
                subscriptions: options.subscriptions,
                planAgents: options.planAgents,
                diagnostics: TapQDiagnosticEmitter(category: "startup", sink: sink))
        } catch {
            crash(error, fatal: fatal)
        }

        let writer = KernelStatusWriter(versionOverride: startup.versionOverride, sink: sink)
        let kernel = await KernelComposition.compose(options: options,
                                                     permissionMode: permissionMode,
                                                     kernelDirectory: directory,
                                                     startup: startup,
                                                     environment: environment,
                                                     sink: sink,
                                                     fatal: fatal,
                                                     status: writer.write)
        KernelShutdownSignals.shutdown = { kernel.shutdown() }
        await kernel.run()
        exit(0)
    }
    #endif

    // MARK: - Doors out

    /// `EX_USAGE`, with the usage text: every one of these is a line somebody can retype.
    static func refuse(_ error: any Error) -> Never {
        try? FileHandle.standardError.write(
            contentsOf: Data("tapq-kernel: \(error)\n\n\(KernelCommandLine.usage)\n".utf8))
        exit(64)
    }

    /// `ProcessFatal` exits; the trailing `exit` only tells the compiler so.
    @MainActor
    static func crash(_ error: any Error, fatal: ProcessFatal) -> Never {
        if let failure = error as? KernelStartupFailure {
            fatal.crash(FatalReason(subsystem: failure.subsystem, reason: failure.reason,
                                    context: failure.context))
        } else {
            fatal.crash(FatalReason(subsystem: "startup", reason: "\(error)"))
        }
        exit(ProcessFatal.exitCode)
    }
}

/// A flag the kernel's grammar knows that this build cannot honor: a usage refusal, before
/// anything has started.
struct UnavailableFlag: Error, CustomStringConvertible {
    let flag: String

    var description: String { "\(flag) is not available in this build" }
}
