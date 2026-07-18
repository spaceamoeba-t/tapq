import Foundation

enum CalibrationPhase: Equatable {
    case resting
    case nod
    case shake
    case tap
}

struct CalibrationStage: Equatable {
    let phase: CalibrationPhase?
    let title: String
    let instruction: String
    let duration: TimeInterval
}

/// One continuous capture timeline. Warmup and transition stages deliberately discard
/// samples so connection establishment and changes between gestures do not contaminate
/// the calibration windows.
struct CalibrationTimeline: Equatable {
    static let warmupDuration: TimeInterval = 1
    static let transitionDuration: TimeInterval = 1

    let stages: [CalibrationStage]

    init(options: CalibrationRunOptions) {
        var result = [
            CalibrationStage(
                phase: nil,
                title: "Connecting",
                instruction: "Hold still while headphone motion stabilizes.",
                duration: Self.warmupDuration
            ),
            CalibrationStage(
                phase: .resting,
                title: "Resting baseline",
                instruction: "Keep your head still and face forward.",
                duration: options.restDuration
            ),
        ]

        if options.target != .tap {
            result += [Self.transition(to: "nod"), CalibrationStage(
                phase: .nod,
                title: "Nod",
                instruction: "Nod naturally several times.",
                duration: options.nodDuration
            ), Self.transition(to: "shake"), CalibrationStage(
                phase: .shake,
                title: "Shake",
                instruction: "Shake your head naturally several times.",
                duration: options.shakeDuration
            )]
        }

        if options.target != .gesture {
            result += [Self.transition(to: "tap"), CalibrationStage(
                phase: .tap,
                title: "Tap",
                instruction: "Keep your head still and give the outside of an earbud several quick fingertip taps. Do not squeeze or press the stem.",
                duration: options.tapDuration
            )]
        }

        stages = result
    }

    var totalDuration: TimeInterval {
        stages.reduce(0) { $0 + $1.duration }
    }

    func phase(at elapsed: TimeInterval) -> CalibrationPhase? {
        guard elapsed >= 0 else { return nil }
        var boundary: TimeInterval = 0
        for stage in stages {
            boundary += stage.duration
            if elapsed < boundary { return stage.phase }
        }
        return nil
    }

    private static func transition(to next: String) -> CalibrationStage {
        CalibrationStage(
            phase: nil,
            title: "Get ready",
            instruction: "Next: \(next).",
            duration: transitionDuration
        )
    }
}
