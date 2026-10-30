import Foundation
import TapQContracts
import TapQKernel
import TapQPOSIXSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(TapQAudioIO)
import TapQAudioIO
import TapQKernelClaude
import TapQKernelCodex
import TapQOpenAI
import TapQVoiceBackends
import TapQVoiceIO

/// Everything `tapq-kernel run` is, in one function: speech input and output, the text
/// models, the delegates and the kernel. It constructs, and opens the speech output so TapQ
/// can speak before it listens; `Kernel.run()` starts everything else.
@MainActor
enum KernelComposition {
    static func compose(options: KernelCommandLine,
                        permissionMode: ClaudePermissionMode,
                        kernelDirectory: URL,
                        startup: KernelStartup.Checked,
                        environment: [String: String],
                        sink: any TapQDiagnosticSink,
                        fatal: ProcessFatal,
                        status: @escaping @MainActor (StatusReport) -> Void) async -> Kernel {
        let diagnostics = TapQDiagnosticEmitter(category: "kernel", sink: sink)
        let store = JournalStore(directory: kernelDirectory, diagnostics: sink)
        diagnostics.record(store.exists ? "run.resume" : "run.fresh",
                           fields: ["installed": startup.installed.map(\.rawValue).sorted()
                               .joined(separator: ",")])

        let playback = BackendAudioPlayback(diagnosticSink: sink)
        playback.onUnavailable = { reason in
            fatal.crash(FatalReason(subsystem: FatalReason.Subsystem.speechOutput, reason: reason))
        }
        // An override is a peer speaking the same wire. Each session adds its own query to
        // it, as to the service's URL: the default endpoint's here, `?model=` for speech.
        let transcriptionQuery = "?" + (RealtimeTranscriptionSession.defaultEndpoint.query ?? "")
        let transcriptionEndpoint = options.realtimeEndpoint.map {
            URL(string: transcriptionQuery, relativeTo: $0)?.absoluteURL ?? $0
        } ?? RealtimeTranscriptionSession.defaultEndpoint
        let transcription = RealtimeSpeechInput.configuration(environment: environment, language: options.language)
        let speech = RealtimeSpeechOutput.configuration(environment: environment)
        let speechEndpoint = options.realtimeEndpoint ?? RealtimeDefaults.endpoint

        // Every session and call on the user's key.
        let apiKey = startup.apiKey
        let input = RealtimeSpeechInput(
            capture: MicrophonePCMCapture(format: .pcm16Mono24k, diagnosticSink: sink),
            makeSession: {
                RealtimeTranscriptionSession(apiKey: apiKey, configuration: transcription,
                                             endpoint: transcriptionEndpoint, diagnosticSink: sink)
            },
            selfAudio: { playback.selfAudioActivity },
            hysteresis: VoiceSelfAudioEcho.resolvedHysteresis(environment: environment),
            diagnosticSink: sink)
        let output = RealtimeSpeechOutput(
            makeSession: {
                RealtimeSpeechSession(apiKey: apiKey, configuration: speech, endpoint: speechEndpoint,
                                      diagnosticSink: sink)
            },
            player: playback,
            monotonicNow: { ProcessInfo.processInfo.systemUptime },
            diagnosticSink: sink)
        do {
            try await output.open()
        } catch {
            fatal.crash(FatalReason(subsystem: FatalReason.Subsystem.speechOutput,
                                    reason: "open failed: \(error)"))
        }
        let client = OpenAIClient(apiKey: apiKey, baseURL: options.openAIBaseURL ?? OpenAIClient.defaultBaseURL,
                                  http: URLSessionHTTPSender())

        // The packet timeouts are the voice sessions' own; the kernel's intent and summary
        // bounds (5 s, 15 s) are the whole-call deadlines.

        var configuration = KernelConfiguration(workspace: options.workspace, installed: startup.installed)
        configuration.workspaceRealPath = resolvedRealPath(options.workspace.path)
        configuration.notOnPlan = startup.notOnPlan
        return Kernel(
            configuration: configuration,
            journal: Journal(store: store, now: { Date() }),
            sessions: KernelSessionStore(directory: kernelDirectory),
            delegates: delegates(options: options, permissionMode: permissionMode,
                                 startup: startup, environment: environment, sink: sink),
            input: input,
            output: output,
            intent: OpenAIIntentModel(client: client,
                                      model: OpenAIIntentModel.resolvedModel(environment: environment),
                                      diagnostics: sink),
            summarizer: OpenAIReplySummarizer(
                client: client, model: OpenAIReplySummarizer.resolvedModel(environment: environment)),
            describer: OpenAICommandDescriber(
                client: client, model: OpenAICommandDescriber.resolvedModel(environment: environment)),
            progressSummarizer: OpenAIProgressSummarizer(
                client: client, model: OpenAIProgressSummarizer.resolvedModel(environment: environment)),
            catalogs: catalogs(startup: startup, environment: environment),
            titler: OpenAIConversationTitler(
                client: client, model: OpenAIConversationTitler.resolvedModel(environment: environment)),
            picker: OpenAIConversationPicker(
                client: client, model: OpenAIConversationPicker.resolvedModel(environment: environment)),
            fatal: fatal,
            diagnostics: sink,
            status: status,
            monotonicNow: { ProcessInfo.processInfo.systemUptime })
    }

    /// One delegate factory per installed agent: each delegate in an environment without
    /// TapQ's variables or the key, and without an API key when it uses the subscription. No
    /// process starts until the user says yes to a launch; a failed agent gets a fresh delegate.
    private static func delegates(options: KernelCommandLine,
                                  permissionMode: ClaudePermissionMode,
                                  startup: KernelStartup.Checked,
                                  environment: [String: String],
                                  sink: any TapQDiagnosticSink) -> [AgentID: DelegateFactory] {
        var delegates: [AgentID: DelegateFactory] = [:]
        if let path = startup.executables[.claude] {
            delegates[.claude] = { ClaudeDelegate(
                configuration: .init(workspace: options.workspace,
                                     permissionMode: permissionMode,
                                     model: ClaudeLaunchSpec.resolvedModel(environment: environment),
                                     executableOverride: path,
                                     checkedVersion: startup.versions[.claude],
                                     allowsUnsupportedVersion: startup.versionOverride),
                environment: startup.environment(for: .claude, from: environment),
                diagnostics: sink) }
        }
        if let path = startup.executables[.codex] {
            delegates[.codex] = { CodexDelegate(
                configuration: .init(workspace: options.workspace,
                                     executablePath: path,
                                     clientVersion: clientVersion,
                                     model: CodexDelegate.resolvedModel(environment: environment),
                                     allowsUnsupportedVersion: startup.versionOverride,
                                     reviewer: options.autoMode ? .autoReview : .user),
                environment: startup.environment(for: .codex, from: environment),
                spawn: CodexDelegate.spawnChildProcess,
                diagnostics: sink) }
        }
        return delegates
    }

    /// Where each installed agent keeps its conversations: read in the environment the agent
    /// gets, so Claude Code's `CLAUDE_CONFIG_DIR` and Codex's `CODEX_HOME` are the agent's.
    private static func catalogs(startup: KernelStartup.Checked,
                                 environment: [String: String]) -> [AgentID: any SessionCatalog] {
        var catalogs: [AgentID: any SessionCatalog] = [:]
        if let path = startup.executables[.claude] {
            catalogs[.claude] = ClaudeSessionCatalog(environment: startup.environment(for: .claude, from: environment),
                                                     executablePath: path, version: startup.versions[.claude])
        }
        if let path = startup.executables[.codex] {
            catalogs[.codex] = CodexSessionCatalog(
                configuration: .init(executablePath: path, clientVersion: clientVersion,
                                     allowsUnsupportedVersion: startup.versionOverride),
                environment: startup.environment(for: .codex, from: environment),
                spawn: CodexSessionCatalog.spawnChildProcess)
        }
        return catalogs
    }

    /// TapQ's version for Codex's `clientInfo`: the embedded Info.plist, which
    /// `scripts/check-release-version.sh` keeps equal to `VERSION`.
    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }
}
#endif

/// SIGINT, SIGTERM, SIGHUP and standard input's end of file, turned into one orderly
/// shutdown. A closed terminal (SIGHUP) stops the delegates like any other request.
///
/// Installed before the startup checks. Until `shutdown` is set, that is until the kernel
/// exists, a request exits 0 at once, killing any version probe's group first.
///
/// Dispatch sources rather than `signal(2)` handlers: a handler runs on whatever thread was
/// interrupted, under async-signal-safety rules that forbid everything this needs to do. The
/// default disposition is ignored first, or the process dies before the source is asked.
///
/// Standard input is a host's lifeline: a host holds the pipe open and never writes, so end
/// of file means the host is gone. Always watched; a terminal user ends a run with ^D or ^C.
@MainActor
enum KernelShutdownSignals {
    static var shutdown: (@MainActor () -> Void)?
    private static var sources: [any DispatchSourceSignal] = []
    private static var fired = false

    static func install(sink: any TapQDiagnosticSink) {
        let diagnostics = TapQDiagnosticEmitter(category: "kernel", sink: sink)
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    fire("signal", fields: ["signal": "\(number)"], diagnostics)
                }
            }
            source.resume()
            sources.append(source)
        }
        // A blocking read on its own thread: nothing else reads stdin, and the answer is one
        // event, not a poll.
        DispatchQueue.global(qos: .utility).async {
            _ = try? FileHandle.standardInput.readToEnd()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { fire("stdin.eof", fields: [:], diagnostics) }
            }
        }
    }

    /// The second request is logged, not escalated: the first is already stopping the
    /// delegates within their bounds.
    private static func fire(_ name: String, fields: [String: String],
                             _ diagnostics: TapQDiagnosticEmitter) {
        guard !fired else {
            diagnostics.record("\(name).repeated", fields: fields)
            return
        }
        fired = true
        diagnostics.record(name, fields: fields)
        guard let shutdown else {
            ChildProcess.killAllGroups()
            exit(0)
        }
        shutdown()
    }
}
