import Foundation
import TapQClaudeAdapter
import TapQDetectionBaseline

enum CLIHelpTopic: Equatable {
    case root
    case serve
    case capture
    case replay
    case calibration
    case integration
}

enum CaptureFormat: String, Equatable {
    case jsonl
    case csv
}

struct CaptureOptions: Equatable {
    var duration: TimeInterval = 10
    var outputPath = "-"
    var format: CaptureFormat = .jsonl
    var force = false
}

struct ServeOptions: Equatable {
    var brokerDirectoryPath: String?
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var interactionTimeout: TimeInterval = 100
    var voiceEnabled = true
    var announcementsEnabled = true
    var steeringEnabled = false
    var encoderModelPath: String?
    /// Meaningful only alongside `encoderModelPath`; shadow is the safe default —
    /// the encoder is observed, never trusted, until promoted explicitly.
    var encoderMode: EncoderMode = .shadow
}

struct ReplayOptions: Equatable {
    var inputPath = ""
    var labelsPath: String?
    var format: CaptureFormat?
    var tolerance: TimeInterval = 1.0
    var json = false
    var encoderModelPath: String?
    var gestureProfilePath: String?
    var tapProfilePath: String?
}

enum CalibrationTarget: String, Equatable {
    case all
    case gesture
    case tap

    var profileKinds: [CalibrationProfileKind] {
        switch self {
        case .all: [.gesture, .tap]
        case .gesture: [.gesture]
        case .tap: [.tap]
        }
    }
}

struct CalibrationRunOptions: Equatable {
    var target: CalibrationTarget = .all
    var restDuration: TimeInterval = 3
    var nodDuration: TimeInterval = 4
    var shakeDuration: TimeInterval = 4
    var tapDuration: TimeInterval = 4
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var nonInteractive = false
}

struct CalibrationShowOptions: Equatable {
    var target: CalibrationTarget = .all
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var json = false
}

struct CalibrationResetOptions: Equatable {
    var target: CalibrationTarget = .all
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var confirmed = false
}

enum CalibrationCommand: Equatable {
    case run(CalibrationRunOptions)
    case show(CalibrationShowOptions)
    case reset(CalibrationResetOptions)
}

enum IntegrationAction: String, Equatable {
    case install
    case status
    case uninstall
}

struct ClaudeIntegrationOptions: Equatable {
    let action: IntegrationAction
    var settingsPath: String?
    var hookPath: String?
    var permissionPolicy: ClaudePermissionPolicy = .strict
}

struct CodexIntegrationOptions: Equatable {
    let action: IntegrationAction
    var hooksPath: String?
    var hookPath: String?
}

enum IntegrationOptions: Equatable {
    case claude(ClaudeIntegrationOptions)
    case codex(CodexIntegrationOptions)
}

enum CLICommand: Equatable {
    case help(CLIHelpTopic)
    case version(json: Bool)
    case serve(ServeOptions)
    case capture(CaptureOptions)
    case replay(ReplayOptions)
    case calibration(CalibrationCommand)
    case integration(IntegrationOptions)
}

struct CLIUsageError: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

enum CLICommandParser {
    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { return .help(.root) }
        let rest = Array(arguments.dropFirst())

        switch first {
        case "help", "--help", "-h":
            return .help(try helpTopic(from: rest))
        case "version", "--version", "-V":
            return .version(json: try parseVersion(rest))
        case "serve":
            if isHelp(rest) { return .help(.serve) }
            return .serve(try parseServe(rest))
        case "capture":
            if isHelp(rest) { return .help(.capture) }
            return .capture(try parseCapture(rest))
        case "replay":
            if isHelp(rest) { return .help(.replay) }
            return .replay(try parseReplay(rest))
        case "calibrate":
            if isHelp(rest) { return .help(.calibration) }
            return .calibration(.run(try parseCalibrationRun(rest)))
        case "calibration":
            return try parseCalibration(rest)
        case "integration":
            return try parseIntegration(rest)
        default:
            throw CLIUsageError(message: "Unknown command '\(first)'.")
        }
    }

    private static func helpTopic(from arguments: [String]) throws -> CLIHelpTopic {
        guard let topic = arguments.first else { return .root }
        guard arguments.count == 1 else {
            throw CLIUsageError(message: "Help accepts at most one command name.")
        }
        switch topic {
        case "serve": return .serve
        case "capture": return .capture
        case "replay": return .replay
        case "calibrate", "calibration": return .calibration
        case "integration": return .integration
        default: throw CLIUsageError(message: "Unknown help topic '\(topic)'.")
        }
    }

    private static func parseVersion(_ arguments: [String]) throws -> Bool {
        switch arguments {
        case []: return false
        case ["--json"]: return true
        case ["--help"], ["-h"]: return false
        default: throw CLIUsageError(message: "Usage: tapq version [--json]")
        }
    }

    private static func parseCapture(_ arguments: [String]) throws -> CaptureOptions {
        var options = CaptureOptions()
        var cursor = ArgumentCursor(arguments)
        while let argument = cursor.pop() {
            switch argument {
            case "--duration":
                options.duration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--output", "-o":
                options.outputPath = try cursor.requireValue(for: argument)
            case "--format":
                let value = try cursor.requireValue(for: argument)
                guard let format = CaptureFormat(rawValue: value) else {
                    throw CLIUsageError(message: "--format must be 'jsonl' or 'csv'.")
                }
                options.format = format
            case "--force", "-f":
                options.force = true
            default:
                throw CLIUsageError(message: "Unknown capture option '\(argument)'.")
            }
        }
        return options
    }

    private static func parseServe(_ arguments: [String]) throws -> ServeOptions {
        var options = ServeOptions()
        var encoderModeSpecified = false
        var cursor = ArgumentCursor(arguments)
        while let argument = cursor.pop() {
            switch argument {
            case "--broker-dir":
                options.brokerDirectoryPath = try cursor.requireValue(for: argument)
            case "--gesture-profile":
                options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile":
                options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--timeout":
                options.interactionTimeout = try duration(
                    cursor.requireValue(for: argument), flag: argument)
            case "--no-voice":
                options.voiceEnabled = false
            case "--no-announcements":
                options.announcementsEnabled = false
            case "--steering":
                options.steeringEnabled = true
            case "--encoder-model":
                options.encoderModelPath = try cursor.requireValue(for: argument)
            case "--encoder-mode":
                let value = try cursor.requireValue(for: argument)
                guard let mode = EncoderMode(rawValue: value), mode != .off else {
                    throw CLIUsageError(message: "--encoder-mode must be 'shadow' or 'primary'.")
                }
                options.encoderMode = mode
                encoderModeSpecified = true
            default:
                throw CLIUsageError(message: "Unknown serve option '\(argument)'.")
            }
        }
        if encoderModeSpecified, options.encoderModelPath == nil {
            throw CLIUsageError(message: "--encoder-mode requires --encoder-model.")
        }
        return options
    }

    private static func parseReplay(_ arguments: [String]) throws -> ReplayOptions {
        var options = ReplayOptions()
        var cursor = ArgumentCursor(arguments)
        while let argument = cursor.pop() {
            switch argument {
            case "--input", "-i":
                options.inputPath = try cursor.requireValue(for: argument)
            case "--labels":
                options.labelsPath = try cursor.requireValue(for: argument)
            case "--format":
                let value = try cursor.requireValue(for: argument)
                guard let format = CaptureFormat(rawValue: value) else {
                    throw CLIUsageError(message: "--format must be 'jsonl' or 'csv'.")
                }
                options.format = format
            case "--tolerance":
                options.tolerance = try duration(
                    cursor.requireValue(for: argument), flag: argument)
            case "--json":
                options.json = true
            case "--encoder-model":
                options.encoderModelPath = try cursor.requireValue(for: argument)
            case "--gesture-profile":
                options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile":
                options.tapProfilePath = try cursor.requireValue(for: argument)
            default:
                throw CLIUsageError(message: "Unknown replay option '\(argument)'.")
            }
        }
        guard !options.inputPath.isEmpty else {
            throw CLIUsageError(message: "replay requires --input PATH.")
        }
        return options
    }

    private static func parseCalibration(_ arguments: [String]) throws -> CLICommand {
        guard let action = arguments.first else { return .help(.calibration) }
        let rest = Array(arguments.dropFirst())
        if action == "--help" || action == "-h" { return .help(.calibration) }

        switch action {
        case "run":
            if isHelp(rest) { return .help(.calibration) }
            return .calibration(.run(try parseCalibrationRun(rest)))
        case "show":
            if isHelp(rest) { return .help(.calibration) }
            return .calibration(.show(try parseCalibrationShow(rest)))
        case "reset":
            if isHelp(rest) { return .help(.calibration) }
            return .calibration(.reset(try parseCalibrationReset(rest)))
        default:
            throw CLIUsageError(message: "Unknown calibration action '\(action)'.")
        }
    }

    private static func parseCalibrationRun(_ arguments: [String]) throws -> CalibrationRunOptions {
        let (target, remaining) = try calibrationTarget(from: arguments)
        var options = CalibrationRunOptions(target: target)
        var selectedProfilePath: String?
        var cursor = ArgumentCursor(remaining)
        while let argument = cursor.pop() {
            switch argument {
            case "--rest-seconds":
                options.restDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--nod-seconds":
                options.nodDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--shake-seconds":
                options.shakeDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--tap-seconds":
                options.tapDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--profile":
                selectedProfilePath = try cursor.requireValue(for: argument)
            case "--gesture-profile":
                options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile":
                options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--non-interactive":
                options.nonInteractive = true
            default:
                throw CLIUsageError(message: "Unknown calibration option '\(argument)'.")
            }
        }
        try applySelectedProfilePath(selectedProfilePath, target: target, options: &options)
        return options
    }

    private static func parseCalibrationShow(_ arguments: [String]) throws -> CalibrationShowOptions {
        if isHelp(arguments) { throw CLIUsageError(message: "Usage: tapq calibration show [all|gesture|tap] [--json]") }
        let (target, remaining) = try calibrationTarget(from: arguments)
        var options = CalibrationShowOptions(target: target)
        var selectedProfilePath: String?
        var cursor = ArgumentCursor(remaining)
        while let argument = cursor.pop() {
            switch argument {
            case "--profile": selectedProfilePath = try cursor.requireValue(for: argument)
            case "--gesture-profile": options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile": options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--json": options.json = true
            default: throw CLIUsageError(message: "Unknown calibration show option '\(argument)'.")
            }
        }
        try applySelectedProfilePath(selectedProfilePath, target: target, options: &options)
        return options
    }

    private static func parseCalibrationReset(_ arguments: [String]) throws -> CalibrationResetOptions {
        if isHelp(arguments) { throw CLIUsageError(message: "Usage: tapq calibration reset [all|gesture|tap] [--yes]") }
        let (target, remaining) = try calibrationTarget(from: arguments)
        var options = CalibrationResetOptions(target: target)
        var selectedProfilePath: String?
        var cursor = ArgumentCursor(remaining)
        while let argument = cursor.pop() {
            switch argument {
            case "--profile": selectedProfilePath = try cursor.requireValue(for: argument)
            case "--gesture-profile": options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile": options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--yes", "-y": options.confirmed = true
            default: throw CLIUsageError(message: "Unknown calibration reset option '\(argument)'.")
            }
        }
        try applySelectedProfilePath(selectedProfilePath, target: target, options: &options)
        return options
    }

    private static func calibrationTarget(
        from arguments: [String]
    ) throws -> (CalibrationTarget, [String]) {
        guard let first = arguments.first, !first.hasPrefix("-") else {
            return (.all, arguments)
        }
        guard let target = CalibrationTarget(rawValue: first) else {
            throw CLIUsageError(message: "Calibration target must be 'all', 'gesture', or 'tap'.")
        }
        return (target, Array(arguments.dropFirst()))
    }

    private static func applySelectedProfilePath(
        _ path: String?,
        target: CalibrationTarget,
        options: inout CalibrationRunOptions
    ) throws {
        guard let path else { return }
        switch target {
        case .gesture: options.gestureProfilePath = path
        case .tap: options.tapProfilePath = path
        case .all:
            throw CLIUsageError(message: "--profile requires the gesture or tap target; use --gesture-profile and --tap-profile when targeting all.")
        }
    }

    private static func applySelectedProfilePath(
        _ path: String?,
        target: CalibrationTarget,
        options: inout CalibrationShowOptions
    ) throws {
        guard let path else { return }
        switch target {
        case .gesture: options.gestureProfilePath = path
        case .tap: options.tapProfilePath = path
        case .all:
            throw CLIUsageError(message: "--profile requires the gesture or tap target; use --gesture-profile and --tap-profile when targeting all.")
        }
    }

    private static func applySelectedProfilePath(
        _ path: String?,
        target: CalibrationTarget,
        options: inout CalibrationResetOptions
    ) throws {
        guard let path else { return }
        switch target {
        case .gesture: options.gestureProfilePath = path
        case .tap: options.tapProfilePath = path
        case .all:
            throw CLIUsageError(message: "--profile requires the gesture or tap target; use --gesture-profile and --tap-profile when targeting all.")
        }
    }

    private static func parseIntegration(_ arguments: [String]) throws -> CLICommand {
        guard let provider = arguments.first else { return .help(.integration) }
        if provider == "--help" || provider == "-h" { return .help(.integration) }
        guard provider == "claude" || provider == "codex" else {
            throw CLIUsageError(
                message: "Unknown integration '\(provider)'. Available integrations: 'claude', 'codex'."
            )
        }
        let remaining = Array(arguments.dropFirst())
        guard let actionName = remaining.first else { return .help(.integration) }
        if actionName == "--help" || actionName == "-h" { return .help(.integration) }
        guard let action = IntegrationAction(rawValue: actionName) else {
            throw CLIUsageError(message: "Unknown \(provider) integration action '\(actionName)'.")
        }

        switch provider {
        case "claude":
            var options = ClaudeIntegrationOptions(action: action)
            var cursor = ArgumentCursor(Array(remaining.dropFirst()))
            while let argument = cursor.pop() {
                switch argument {
                case "--settings": options.settingsPath = try cursor.requireValue(for: argument)
                case "--hook": options.hookPath = try cursor.requireValue(for: argument)
                case "--permission-policy":
                    guard action == .install else {
                        throw CLIUsageError(message: "--permission-policy is only valid with 'install'.")
                    }
                    let value = try cursor.requireValue(for: argument)
                    guard let policy = ClaudePermissionPolicy(rawValue: value) else {
                        throw CLIUsageError(message: "--permission-policy must be 'strict' or 'native'.")
                    }
                    options.permissionPolicy = policy
                default:
                    throw CLIUsageError(message: "Unknown Claude integration option '\(argument)'.")
                }
            }
            return .integration(.claude(options))
        case "codex":
            var options = CodexIntegrationOptions(action: action)
            var cursor = ArgumentCursor(Array(remaining.dropFirst()))
            while let argument = cursor.pop() {
                switch argument {
                case "--hooks": options.hooksPath = try cursor.requireValue(for: argument)
                case "--hook": options.hookPath = try cursor.requireValue(for: argument)
                default:
                    throw CLIUsageError(message: "Unknown Codex integration option '\(argument)'.")
                }
            }
            return .integration(.codex(options))
        default:
            preconditionFailure("Validated integration provider")
        }
    }

    private static func duration(_ value: String, flag: String) throws -> TimeInterval {
        guard let parsed = Double(value), parsed.isFinite, parsed > 0, parsed <= 3_600 else {
            throw CLIUsageError(message: "\(flag) must be a number greater than 0 and no more than 3600.")
        }
        return parsed
    }

    private static func isHelp(_ arguments: [String]) -> Bool {
        arguments == ["--help"] || arguments == ["-h"]
    }
}

private struct ArgumentCursor {
    private let arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func pop() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    mutating func requireValue(for flag: String) throws -> String {
        guard let value = pop(), !value.isEmpty,
              value == "-" || !value.hasPrefix("-") else {
            throw CLIUsageError(message: "\(flag) requires a value.")
        }
        return value
    }
}
