import Foundation

/// Everything needed to start one owned agent session, as a value.
///
/// A value rather than a call so the decision and the act are separable: a launcher
/// composes this, a test asserts on it field by field, and only then does a runner turn it
/// into a process. Every spawn TapQ performs is inspectable before it happens.
///
/// Portable and agent-neutral (moved here from the Claude adapter on 2026-09-04, when the
/// Codex launcher needed the same seam): nothing in it knows which CLI it describes.
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
/// Three verbs and a fourth that is the third with one ear. There is nothing here that
/// writes to a child's input: an owned session speaks to TapQ through the broker, like
/// every other session, and a second channel into the same conversation would be a second
/// thing to keep honest. Reading is allowed for exactly one reason — an agent whose session
/// id cannot be chosen up front (Codex) says it on its own standard output, and there is
/// nowhere else to learn it — and a launcher that has no such need uses the deaf verb.
///
/// ``terminate(processIdentifier:)`` is required to be a no-op for any identifier this runner
/// did not itself launch. That is the lowest place the "own children only" rule can be
/// enforced, and it is enforced there so that no bug above it can turn into a signal sent to
/// a session the wearer started at their keyboard.
public protocol OwnedSessionProcessRunning: Sendable {
    /// Starts the child with every standard stream on the null device.
    func launch(_ spawn: OwnedSessionSpawn) -> OwnedSessionSpawnOutcome
    /// Starts the child with its standard output read line by line, on a thread of the
    /// runner's choosing, for as long as the child writes. The runner must keep draining
    /// after the caller stops caring: a pipe nobody reads fills and stops the agent
    /// mid-turn.
    func launch(
        _ spawn: OwnedSessionSpawn,
        standardOutput: @escaping @Sendable (String) -> Void
    ) -> OwnedSessionSpawnOutcome
    /// Whether a child this runner launched is still running. `false` for anything else.
    func isRunning(processIdentifier: Int32) -> Bool
    /// Stops a child this runner launched, gracefully if it will go. Ignores anything else.
    func terminate(processIdentifier: Int32)
}

extension OwnedSessionProcessRunning {
    /// A runner that cannot read — every test double written before the Codex launcher —
    /// starts the child deaf. Only a launcher that *needs* the output should notice, and it
    /// notices as a session that never identifies itself, which the contact timeout ends.
    public func launch(
        _ spawn: OwnedSessionSpawn,
        standardOutput: @escaping @Sendable (String) -> Void
    ) -> OwnedSessionSpawnOutcome {
        launch(spawn)
    }
}

/// What every owned-session launcher lets the composition do with the sessions it owns,
/// beyond starting them.
///
/// One protocol so the runtime can hold a Claude Code launcher and a Codex launcher in one
/// list and ask all of them the same questions: whose session is this, note that it spoke,
/// detach it, sweep, shut down. The rule the whole family enforces is unchanged — a
/// launcher answers for the children it started and for nothing else.
@MainActor public protocol OwnedSessionOwning: AnyObject, OwnedSessionLaunching {
    /// The adapter this launcher starts.
    var agent: AgentIdentity { get }
    /// Called for every ending, however reached.
    var onClosed: (@MainActor (OwnedSessionClosure) -> Void)? { get set }
    /// Confirms that a session TapQ started has reached the broker. `false` for a
    /// session this launcher did not start.
    @discardableResult func noteContact(sessionID: String) -> Bool
    /// Whether `sessionID` names a session this launcher started.
    func owns(sessionID: String) -> Bool
    /// The focus moved away from one of this launcher's sessions: wind it down.
    @discardableResult func detach(sessionID: String, now: Date) -> Bool
    /// Whether one of this launcher's sessions has been detached and is winding down.
    func isDetached(sessionID: String) -> Bool
    /// Closes the sessions that are over.
    @discardableResult func sweep(now: Date) -> [OwnedSessionClosure]
    /// Stops every session this launcher owns, and only those.
    @discardableResult func shutdown() -> [OwnedSessionClosure]
}

/// The variable an owned session's hooks read to know the session exists only to talk to
/// the wearer. Set to `"1"` on the child's environment by every launcher.
public enum OwnedSessionEnvironment {
    public static let ownedSessionKey = "TAPQ_OWNED_SESSION"
}

/// The wearer's goal in the shape an argument vector can carry.
public enum OwnedSessionPrompt {
    /// The goal as one line of text, or `nil` when nothing is left of it.
    ///
    /// Three rules, and only the third is a judgement call. Whitespace — including the
    /// newlines a recognizer never produces but a caller might — collapses to single spaces,
    /// and control characters are dropped, so the prompt is one line of text. Length is
    /// bounded by ``OwnedSessionBudget/maximumGoalCharacters``, which a spoken sentence
    /// never approaches and a recognizer that failed to endpoint would sail past.
    ///
    /// And leading hyphens are stripped: a goal beginning with one would be read by the CLI
    /// as a flag rather than as the prompt, which is the one way a transcript could reach
    /// past the argument it is supposed to be. Spoken goals do not begin with hyphens, so the
    /// rule costs nothing real and closes the hole rather than trusting the parser to.
    public static func text(from goal: String) -> String? {
        var collapsed = ""
        var pendingSeparator = false
        for character in goal {
            if character.isWhitespace {
                pendingSeparator = !collapsed.isEmpty
                continue
            }
            if character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                continue
            }
            if pendingSeparator {
                collapsed.append(" ")
                pendingSeparator = false
            }
            collapsed.append(character)
        }
        let unflagged = collapsed.drop(while: { $0 == "-" })
            .trimmingCharacters(in: .whitespaces)
        guard !unflagged.isEmpty else { return nil }
        guard unflagged.count > OwnedSessionBudget.maximumGoalCharacters else { return unflagged }
        return String(unflagged.prefix(OwnedSessionBudget.maximumGoalCharacters))
    }
}

/// Where an agent CLI is, decided once by TapQ from an environment it can see.
public enum OwnedSessionExecutable {
    /// The absolute path of `name` on `PATH`, or `nil`.
    ///
    /// The same scan `CodexCLIProcessRunner` performs, and for the same reason: TapQ decides
    /// which executable it is starting, once, rather than handing a bare name to the
    /// process machinery and finding out afterwards.
    public static func resolve(
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

    /// Whether `path` is a directory a session can be started in.
    public static func isUsableDirectory(_ path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
