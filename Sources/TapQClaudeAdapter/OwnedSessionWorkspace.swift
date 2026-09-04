import Foundation
import TapQContracts

/// Why TapQ could not make a folder for a session it was asked to start.
///
/// Both cases are refusals, not degradations. A session with nowhere to work cannot be
/// started somewhere else that seemed close enough, and a folder whose hooks were not
/// written would run a session TapQ could see start and then never hear from again — the
/// worst of the failures, because it looks like success until the wearer waits for an
/// answer that no hook will ever bring.
///
/// `git init` is deliberately not here. See ``OwnedSessionWorkspace/makeSessionDirectory(goal:)``.
public enum OwnedSessionWorkspaceError: Error, LocalizedError, Equatable {
    /// The workspace root, or a folder under it, could not be created.
    case unwritable(path: String)
    /// The folder exists but TapQ's hooks could not be written into it.
    case hooksNotWritten(path: String)

    /// Closed, context-free kind for diagnostics.
    public var reasonKind: String {
        switch self {
        case .unwritable: return "unwritable"
        case .hooksNotWritten: return "hooks_not_written"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unwritable(let path):
            return "TapQ could not create a working folder at \(path)."
        case .hooksNotWritten(let path):
            return "TapQ could not write its hooks into \(path)."
        }
    }
}

/// A non-zero `git init`. Never surfaces: the caller turns it into a warning.
struct GitInitFailure: Error {
    let status: Int32
}

/// The folders TapQ makes for sessions it starts (`docs/WAKE_WORD_PLAN.md` §5).
///
/// A session started by the wearer's voice with nothing else running has nowhere to work:
/// no focused session has carried a directory, and `--session-directory` may not have been
/// given. Before this type the answer was a spoken refusal. Now it is a folder under the
/// wearer's home that TapQ makes, hooks, and hands over — which is also the only place
/// TapQ writes anything of the wearer's outside its own configuration, so the type is
/// deliberately small and every failure in it is a refusal rather than a guess.
///
/// The hooks go into the *folder*, never into the wearer's user-level Claude settings.
/// That is the same rule `--session-directory` already follows: a session TapQ starts is
/// visible to TapQ because of where it runs, and a wearer's ordinary keyboard sessions
/// elsewhere are untouched.
public struct OwnedSessionWorkspace {
    /// The root the folders are made under, e.g. `~/TapQ/sessions` already expanded.
    public let root: String
    /// The hook shim command written into each folder's `.claude/settings.json` — the same
    /// string the runtime hands the launcher, so the launcher's hook check reads back what
    /// this wrote.
    public let hookCommand: String
    /// Whether a new folder gets `git init`.
    public let gitInit: Bool
    private let fileManager: FileManager
    private let now: () -> Date
    private let gitInitializer: (URL) throws -> Void
    private let diagnostics: TapQDiagnosticEmitter

    /// Folder names are `<yyyy-MM-dd-HHmm>-<slug>`: sortable, readable, and local — the
    /// wearer reads these in Finder, so the wall clock they were standing in is the right
    /// one. POSIX locale so a wearer's calendar preference cannot produce a non-Gregorian
    /// folder name.
    private static let stampFormat = "yyyy-MM-dd-HHmm"

    /// How many collision suffixes to try before giving up. A wearer starting a fiftieth
    /// session in the same minute with the same first four words has hit something other
    /// than a naming problem.
    private static let maxCollisionAttempts = 50

    /// Cap on the slug, so one absurd "word" cannot produce a path the filesystem refuses.
    private static let maxSlugLength = 60

    /// The name a folder gets when there is no goal to make one from.
    static let goallessSlug = "session"

    public init(
        root: String,
        hookCommand: String,
        gitInit: Bool = true,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() },
        gitInitializer: @escaping (URL) throws -> Void = OwnedSessionWorkspace.gitInit(in:),
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.root = root
        self.hookCommand = hookCommand
        self.gitInit = gitInit
        self.fileManager = fileManager
        self.now = now
        self.gitInitializer = gitInitializer
        self.diagnostics = TapQDiagnosticEmitter(
            category: "OwnedSessionWorkspace", sink: diagnosticSink
        )
    }

    /// Makes a folder for one session and returns its absolute path.
    ///
    /// `goal` is the wearer's own sentence, or `""` when they asked for a session without
    /// saying what for. It is **not** the prompt the runtime substitutes for a goalless
    /// launch: that prompt is a paragraph of instructions to the agent, and slugging its
    /// first four words would name the folder after TapQ talking to itself. The caller
    /// passes what the wearer said, and passes the empty string when they said nothing.
    ///
    /// Three things happen, in an order chosen so a failure leaves as little behind as
    /// possible: the folder is created, the hooks are written, and only then is `git init`
    /// attempted. The first two throw. The third does not — a machine without git, or a
    /// git that refuses, is a warning in the diagnostics and nothing else. The repository
    /// exists to spare the wearer one conversational turn (hardware run 5: the first thing
    /// Claude asked in a bare folder was whether to initialize one), and refusing the whole
    /// session over a convenience would be the wrong trade by a wide margin.
    public func makeSessionDirectory(goal: String) throws -> String {
        try createRootIfNeeded()
        let directory = try createUniqueDirectory(named: baseName(for: goal))
        do {
            try HookInstaller(
                settingsURL: directory.appendingPathComponent(".claude/settings.json"),
                hookCommand: hookCommand
            ).install()
        } catch {
            diagnostics.record("hooks_failed", level: .error, fields: [
                "path": directory.path, "error": "\(error)",
            ])
            throw OwnedSessionWorkspaceError.hooksNotWritten(path: directory.path)
        }
        if gitInit { runGitInit(in: directory) }
        diagnostics.record("created", fields: [
            "path": directory.path, "git": gitInit ? "yes" : "no",
        ])
        return directory.path
    }

    // MARK: - Naming

    /// `<yyyy-MM-dd-HHmm>-<slug>`, before any collision suffix.
    func baseName(for goal: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Self.stampFormat
        return "\(formatter.string(from: now()))-\(Self.slug(for: goal))"
    }

    /// The first four words of the goal, lowercased, with everything that is not a letter
    /// or a digit becoming a hyphen — and `session` when that leaves nothing.
    ///
    /// Four words is enough to recognize a folder a week later and short enough that the
    /// path stays readable. It is a label, not a summary: the goal itself is written to the
    /// session book, which is where "what was this one for" is actually answered.
    static func slug(for goal: String) -> String {
        let words = goal.split(whereSeparator: { $0.isWhitespace }).prefix(4)
        let hyphenated = words.joined(separator: "-").lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        var slug = String(hyphenated)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > maxSlugLength {
            slug = String(slug.prefix(maxSlugLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug.isEmpty ? goallessSlug : slug
    }

    // MARK: - Filesystem

    private func createRootIfNeeded() throws {
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: root, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw OwnedSessionWorkspaceError.unwritable(path: root)
            }
            return
        }
        do {
            try fileManager.createDirectory(
                atPath: root, withIntermediateDirectories: true
            )
            diagnostics.record("root_created", fields: ["path": root])
        } catch {
            diagnostics.record("root_failed", level: .error, fields: [
                "path": root, "error": "\(error)",
            ])
            throw OwnedSessionWorkspaceError.unwritable(path: root)
        }
    }

    /// Creates `<root>/<base>`, or `<base>-2`, `-3`, … if that name is taken.
    ///
    /// `withIntermediateDirectories: false` is the point: it fails rather than succeeding
    /// silently when the folder already exists, so the collision check is the creation
    /// itself and there is no window between looking and making.
    private func createUniqueDirectory(named base: String) throws -> URL {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        for attempt in 1...Self.maxCollisionAttempts {
            let name = attempt == 1 ? base : "\(base)-\(attempt)"
            let candidate = rootURL.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) { continue }
            do {
                try fileManager.createDirectory(
                    at: candidate, withIntermediateDirectories: false
                )
                return candidate
            } catch {
                // Lost a race, or cannot write here at all. The former is answered by the
                // next suffix; the latter will exhaust the loop and be refused below.
                if fileManager.fileExists(atPath: candidate.path) { continue }
                diagnostics.record("directory_failed", level: .error, fields: [
                    "path": candidate.path, "error": "\(error)",
                ])
                throw OwnedSessionWorkspaceError.unwritable(path: candidate.path)
            }
        }
        throw OwnedSessionWorkspaceError.unwritable(path: rootURL.path)
    }

    /// Best-effort `git init`. Never throws out of here: see `makeSessionDirectory(goal:)`.
    private func runGitInit(in directory: URL) {
        do {
            try gitInitializer(directory)
            diagnostics.record("git_initialized", fields: ["path": directory.path])
        } catch {
            diagnostics.record("git_failed", level: .warning, fields: [
                "path": directory.path, "error": "\(error)",
            ])
        }
    }

    /// Why the repository is a closure and not a call: this is the only line in the type
    /// that spawns a process, and `Foundation.Process` cannot be exercised from the Linux
    /// test container — `waitUntilExit()` inside XCTest there stalls the whole suite, which
    /// is what this seam was extracted to stop. The default is the real thing and runs
    /// under the macOS leg of CI; every other test drives a closure and spawns nothing.
    public static func gitInit(in directory: URL) throws {
        let process = Process()
        // Through `env` rather than a guessed absolute path, so a git from Homebrew, Xcode,
        // or a Nix profile is all the same to TapQ — and so a machine with no git at all
        // fails as a non-zero exit rather than as a crash on a missing executable.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "-q"]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitInitFailure(status: process.terminationStatus)
        }
    }
}
