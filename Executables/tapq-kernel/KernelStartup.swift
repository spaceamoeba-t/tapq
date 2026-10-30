import Foundation
import TapQContracts
import TapQKernel
import TapQKernelClaude
import TapQKernelCodex
import TapQPOSIXSupport

/// A startup check that failed, in the shape `FatalReason` wants: exit 70 with one line.
struct KernelStartupFailure: Error, CustomStringConvertible {
    let subsystem: String
    let reason: String
    var context: [String: String] = [:]

    var description: String { reason }
}

/// What has to hold before audio opens: the OpenAI key, every installed agent at a supported
/// version, and the subscription login of every agent asked to use one. Each failure is one
/// line naming what is wrong.
enum KernelStartup {
    static let diagnosticsFileName = "diagnostics.log"
    static let apiKeyVariable = "TAPQ_OPENAI_API_KEY"
    /// The developer's override: an unsupported agent version runs, with a warning on every
    /// launch and `versionOverride: true` on every status line.
    static let versionOverrideVariable = "TAPQ_ALLOW_UNSUPPORTED_AGENT_VERSIONS"

    /// A `--version` or login status that has not answered by then is a broken install,
    /// not a slow one.
    static let probeBound: Duration = .seconds(10)

    struct Checked {
        /// The key every speech session and text-model call runs on.
        let apiKey: String
        /// The resolved executable of every installed agent. An agent not on `PATH` is
        /// absent, and the kernel answers "isn't installed" when it is addressed.
        let executables: [AgentID: String]
        /// The version each installed agent reported, when it parsed. Claude's is
        /// cross-checked against its first `system/init`.
        let versions: [AgentID: String]
        let versionOverride: Bool
        /// The installed agents that sign in with the user's subscription, and the account
        /// each reported. Every other agent gets the environment as it is.
        let subscriptions: [AgentID: SubscriptionAccount]
        /// The agents `--agents` leaves out: never probed nor started.
        var notOnPlan: Set<AgentID> = []

        var installed: Set<AgentID> { Set(executables.keys) }

        /// What `agent`'s process is started with: its adapter's sanitized environment, less
        /// what would outrank its login when it uses the subscription.
        func environment(for agent: AgentID, from environment: [String: String]) -> [String: String] {
            guard let support = AgentSupport(agent) else { return environment }
            let sanitized = support.sanitized(environment)
            guard subscriptions[agent] != nil, let login = support.subscription else { return sanitized }
            return login.environment(sanitized)
        }
    }

    /// What each coding agent's adapter says about its own CLI: the name on `PATH`, the
    /// supported range, how its `--version` reads, and the environment it may see (no key, no
    /// `TAPQ_*`). A chat agent is an app, not a CLI, and has none.
    struct AgentSupport {
        let executableName: String
        let range: VersionRange
        let parse: (String) -> String?
        let sanitized: ([String: String]) -> [String: String]
        /// How the CLI signs in with the user's subscription; `nil` where TapQ cannot yet.
        let subscription: SubscriptionLogin?

        init?(_ agent: AgentID) {
            switch agent {
            case .claude:
                executableName = ClaudeExecutable.name
                range = ClaudeVersions.supported
                parse = { ClaudeVersions.parse(versionOutput: $0) }
                sanitized = ClaudeEnvironment.sanitized
                subscription = ClaudeSubscription.login
            case .codex:
                executableName = CodexLaunchSpec.executableName
                range = CodexVersions.supported
                parse = { CodexVersions.parse(versionOutput: $0) }
                sanitized = CodexLaunchSpec.sanitized
                subscription = nil
            case .claudeChat, .chatgpt:
                return nil
            }
        }
    }

    /// `workspace` is where the agents run, which an empty `PATH` entry names.
    /// `subscriptions` are the agents asked to sign in with the user's own login.
    /// `planAgents` are the agents `--agents` names; `nil` is every agent.
    static func check(workspace: URL,
                      environment: [String: String],
                      subscriptions: Set<AgentID> = [],
                      planAgents: Set<AgentID>? = nil,
                      diagnostics: TapQDiagnosticEmitter) async throws -> Checked {
        guard let apiKey = trimmed(environment[apiKeyVariable]) else {
            throw KernelStartupFailure(subsystem: "startup", reason: "\(apiKeyVariable) is not set")
        }
        let notOnPlan = planAgents.map { Set(AgentID.mac).subtracting($0) } ?? []
        for agent in AgentID.mac where notOnPlan.contains(agent) {
            diagnostics.record("agent.left_out", fields: ["agent": agent.rawValue])
        }
        let versionOverride = environment[versionOverrideVariable] == "1"
        if versionOverride {
            diagnostics.record("agent.version_override", level: .warning,
                               fields: ["variable": versionOverrideVariable])
        }

        var executables: [AgentID: String] = [:]
        var versions: [AgentID: String] = [:]
        for agent in AgentID.allCases where !notOnPlan.contains(agent) {
            guard let support = AgentSupport(agent) else { continue }
            guard let path = OwnedSessionExecutable.resolve(
                named: support.executableName, environment: environment,
                workingDirectoryPath: workspace.path) else {
                diagnostics.record("agent.not_installed", fields: ["agent": agent.rawValue])
                continue
            }
            let output = try await probe(agent, executable: path, arguments: ["--version"],
                                         environment: support.sanitized(environment))
            let parsed = support.parse(output)
            let found = parsed ?? output
            if !support.range.contains(found) {
                guard versionOverride else {
                    throw KernelStartupFailure(subsystem: FatalReason.Subsystem.delegate(agent),
                                               reason: support.range.refusal(for: agent, found: found),
                                               context: ["path": path])
                }
                diagnostics.record("agent.version_unsupported", level: .warning,
                                   fields: ["agent": agent.rawValue, "version": found])
            }
            diagnostics.record("agent.installed",
                               fields: ["agent": agent.rawValue, "path": path, "version": found])
            executables[agent] = path
            versions[agent] = parsed
        }

        var accounts: [AgentID: SubscriptionAccount] = [:]
        for agent in AgentID.allCases where subscriptions.contains(agent) {
            guard let path = executables[agent] else { continue }  // "isn't installed" when asked
            accounts[agent] = try await subscriptionAccount(agent, executable: path,
                                                            workspace: workspace,
                                                            environment: environment,
                                                            diagnostics: diagnostics)
        }
        return Checked(apiKey: apiKey, executables: executables, versions: versions,
                       versionOverride: versionOverride, subscriptions: accounts, notOnPlan: notOnPlan)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The agent's own report of its login, asked in the environment and folder its process
    /// will have: an `apiKeyHelper` in the workspace's settings would win at launch, so the
    /// probe must see it too. Anything but a subscription login refuses the start; falling
    /// back to a key would bill what the user asked TapQ not to.
    static func subscriptionAccount(_ agent: AgentID,
                                    executable: String,
                                    workspace: URL,
                                    environment: [String: String],
                                    diagnostics: TapQDiagnosticEmitter) async throws -> SubscriptionAccount {
        let subsystem = FatalReason.Subsystem.delegate(agent)
        guard let support = AgentSupport(agent), let login = support.subscription else {
            throw KernelStartupFailure(
                subsystem: subsystem,
                reason: "TapQ cannot use \(agent.displayName)'s subscription login yet")
        }
        let output = try await probe(agent, executable: executable,
                                     arguments: login.statusArguments,
                                     environment: login.environment(support.sanitized(environment)),
                                     workingDirectory: workspace,
                                     requireSuccess: false)
        let account: SubscriptionAccount
        switch login.parse(output) {
        case .account(let found):
            account = found
        case .notSubscription(let why):
            throw KernelStartupFailure(
                subsystem: subsystem,
                reason: "\(agent.displayName) can't use your subscription: \(why). Sign in with "
                    + "'\(login.loginCommand)', or turn the subscription off")
        }
        diagnostics.record("agent.subscription", fields: [
            "agent": agent.rawValue, "method": account.method, "plan": account.plan ?? "unknown",
        ])
        return account
    }

    /// `<executable> <arguments>`, bounded, its standard output trimmed. `--version` is also
    /// the cheapest proof that the binary runs at all: an npm shim pointing at a deleted node
    /// fails here, not on the user's first sentence. A probe still running at the bound is
    /// left to the fatal that follows, which kills every child group. Without
    /// `requireSuccess` a non-zero exit is the caller's to read (a logged-out status may say
    /// so with one).
    static func probe(_ agent: AgentID,
                      executable: String,
                      arguments: [String],
                      environment: [String: String],
                      workingDirectory: URL = URL(fileURLWithPath: "/"),
                      requireSuccess: Bool = true) async throws -> String {
        let subsystem = FatalReason.Subsystem.delegate(agent)
        let command = ([executable] + arguments).joined(separator: " ")
        let child: ChildProcess
        do {
            child = try ChildProcess(executable: executable, arguments: arguments,
                                     environment: environment,
                                     workingDirectory: workingDirectory)
        } catch {
            throw KernelStartupFailure(subsystem: subsystem,
                                       reason: "could not run '\(command)'",
                                       context: ["error": "\(error)"])
        }
        child.closeInput()
        let reader = Task { () -> (output: [String], exit: Int32?) in
            var output: [String] = []
            for await signal in child.signals {
                switch signal {
                case .stdout(let line): output.append(line)
                case .stderr: continue
                case .exited(let code): return (output, code)
                }
            }
            return (output, nil)
        }
        let bound = Task {
            try await Task.sleep(for: probeBound)
            reader.cancel()
        }
        let (output, exit) = await reader.value
        bound.cancel()
        guard let exit else {
            throw KernelStartupFailure(
                subsystem: subsystem,
                reason: "'\(command)' did not answer within "
                    + "\(probeBound.components.seconds) seconds")
        }
        let text = output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requireSuccess || (exit == 0 && !text.isEmpty) else {
            throw KernelStartupFailure(subsystem: subsystem,
                                       reason: "'\(command)' did not report a version",
                                       context: ["exit": "\(exit)"])
        }
        return text
    }
}
