import Foundation

/// The account an agent CLI reported it would use: its own login, not an API key.
public struct SubscriptionAccount: Sendable, Equatable {
    /// How the CLI says it signs in, e.g. "claude.ai".
    public let method: String
    /// The plan, when the CLI names one, e.g. "max".
    public let plan: String?

    public init(method: String, plan: String? = nil) {
        self.method = method
        self.plan = plan
    }
}

/// What an agent CLI's login report says about the subscription.
public enum SubscriptionStatus: Sendable, Equatable {
    case account(SubscriptionAccount)
    /// What the CLI would use instead, in words for the user ("it is not signed in"). Never
    /// the raw report: it can carry the account's email.
    case notSubscription(String)
}

/// How an agent's CLI is made to use the user's own subscription login instead of an API
/// key from the environment. Each delegate adapter supplies one, or none when TapQ cannot
/// do it for that CLI yet; the kernel's startup runs it the same way for every agent.
///
/// Off unless asked for (`--subscription`): without it the agent's environment is exactly
/// what it was, API keys included.
public struct SubscriptionLogin: Sendable {
    /// Variables that outrank the login in the CLI's own order; left out of its environment.
    public let overridingVariables: [String]
    /// The CLI's arguments for reporting its login, run in the environment it will get.
    public let statusArguments: [String]
    /// That command's standard output read: the account, or why what the CLI would use is
    /// not a subscription login (logged out, an API key, a cloud provider).
    public let parse: @Sendable (String) -> SubscriptionStatus
    /// How the user signs in, said in the refusal when there is no login.
    public let loginCommand: String

    public init(overridingVariables: [String],
                statusArguments: [String],
                loginCommand: String,
                parse: @escaping @Sendable (String) -> SubscriptionStatus) {
        self.overridingVariables = overridingVariables
        self.statusArguments = statusArguments
        self.loginCommand = loginCommand
        self.parse = parse
    }

    /// `environment` without the variables that would win over the login.
    public func environment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !overridingVariables.contains($0.key) }
    }
}
