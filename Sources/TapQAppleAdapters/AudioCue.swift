import Foundation
import TapQContracts
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)
/// The two non-speech cues quiet mode has to distinguish.
///
/// Quiet mode does not remove information, it changes the channel: an utterance the wearer
/// would otherwise hear becomes a short tone. Two tones are enough, because the only thing
/// the wearer has to decide on hearing one is whether it is their turn.
public enum AudioCueKind: String, Sendable, CaseIterable {
    /// Something is waiting for an answer — an approval prompt, a stop question, an open
    /// command window. Rising two-tone: the ear reads rising as "over to you".
    case prompt
    /// Something happened that the wearer does not have to answer — a session finished,
    /// motion was lost, a request was deferred to the screen. One flat, softer tone.
    case notification
}

/// Plays short non-speech cues. Kept as a protocol so a host can inject a recorder or a
/// no-op without reaching for the audio hardware.
@MainActor public protocol AudioCuePlaying: AnyObject {
    func play(_ kind: AudioCueKind)
}

/// One tone in a cue: a sine burst and the silence that follows it.
struct AudioCueTone: Equatable {
    let frequency: Double
    let duration: TimeInterval
    let gapAfter: TimeInterval
}

/// Generates cue waveforms. Synthesis rather than assets: the cues are two sine bursts, and
/// a package that ships no audio files has no bundle-resource problem to solve on any host.
enum AudioCueSynthesizer {
    /// A rate every current output device handles without the mixer resampling.
    static let sampleRate: Double = 48_000
    /// Deliberately quiet. A cue that competes with speech is a cue the wearer turns off.
    static let amplitude: Double = 0.22
    /// Raised-cosine attack and release. Without it the burst edges click.
    static let fade: TimeInterval = 0.006

    static func tones(for kind: AudioCueKind) -> [AudioCueTone] {
        switch kind {
        case .prompt:
            // A5 then E6: a rising fifth, unmistakable against the flat cue below.
            return [
                AudioCueTone(frequency: 880.0, duration: 0.085, gapAfter: 0.045),
                AudioCueTone(frequency: 1_318.51, duration: 0.11, gapAfter: 0),
            ]
        case .notification:
            // D5, single and longer: lower, flatter, nothing to answer.
            return [AudioCueTone(frequency: 587.33, duration: 0.14, gapAfter: 0)]
        }
    }

    /// Interleaved mono PCM16 for one cue.
    static func samples(for kind: AudioCueKind) -> [Int16] {
        var samples: [Int16] = []
        for tone in tones(for: kind) {
            let frames = Int((tone.duration * sampleRate).rounded())
            guard frames > 0 else { continue }
            let fadeFrames = max(1, min(frames / 2, Int((fade * sampleRate).rounded())))
            for frame in 0..<frames {
                let phase = 2.0 * Double.pi * tone.frequency * Double(frame) / sampleRate
                let value = amplitude
                    * envelope(frame: frame, frames: frames, fadeFrames: fadeFrames)
                    * sin(phase)
                samples.append(Int16(clamping: Int((value * Double(Int16.max)).rounded())))
            }
            let gapFrames = Int((tone.gapAfter * sampleRate).rounded())
            if gapFrames > 0 {
                samples.append(contentsOf: repeatElement(Int16(0), count: gapFrames))
            }
        }
        return samples
    }

    static func buffer(for kind: AudioCueKind) -> AVAudioPCMBuffer? {
        let samples = samples(for: kind)
        guard !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.int16ChannelData else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func envelope(frame: Int, frames: Int, fadeFrames: Int) -> Double {
        let attack = ramp(frame, over: fadeFrames)
        let release = ramp(frames - 1 - frame, over: fadeFrames)
        return min(attack, release)
    }

    private static func ramp(_ position: Int, over fadeFrames: Int) -> Double {
        guard position < fadeFrames else { return 1.0 }
        return 0.5 - 0.5 * cos(Double.pi * Double(max(0, position)) / Double(fadeFrames))
    }
}

/// Plays the quiet-mode cues on an audio engine of its own.
///
/// The engine is deliberately not `BackendAudioPlayback`'s. A cue's whole job is to be
/// audible at moments when the response path is idle, failed, or mid-teardown, and sharing
/// an engine would make the cue inherit that lifecycle — including the fail-open state where
/// a response has given up on audio for the rest of its stream. `AudioCue` owns a
/// `LiveAudioPlaybackScheduler`, which builds a fresh `TapQAudioPlaybackEngine` per start, so
/// nothing here can perturb a response in flight.
///
/// The engine starts on the first cue and stops as soon as the last one drains: cues are
/// tens of milliseconds apart at worst, and an idle audio unit is a battery cost with no
/// upside. Cues overlapping in time simply share the running engine.
///
/// Failure is silence. A cue that cannot be played is a diagnostic, never an error the
/// caller has to handle — the alternative, an interaction that stalls because a tone did not
/// come out, is strictly worse than a missed tone.
@MainActor public final class AudioCue: AudioCuePlaying {
    private let scheduler: AudioPlaybackScheduling
    private let diagnostics: TapQDiagnosticEmitter

    /// Cues scheduled whose completion has not fired yet.
    private var outstanding = 0
    private var engineRunning = false
    /// Bumped by `stop()` and by an engine failure; completions from an older generation
    /// are dropped rather than allowed to stop an engine somebody else has since started.
    private var generation: UInt64 = 0

    /// Production initializer: a dedicated live playback engine.
    public init(diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.scheduler = LiveAudioPlaybackScheduler()
        self.diagnostics = TapQDiagnosticEmitter(category: "AudioCue", sink: diagnosticSink)
    }

    /// Test seam: injects a fake scheduler so the lifecycle is exercised without audio.
    init(scheduler: AudioPlaybackScheduling,
         diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.scheduler = scheduler
        self.diagnostics = TapQDiagnosticEmitter(category: "AudioCue", sink: diagnosticSink)
    }

    /// Whether an engine is currently running for a cue.
    public var isPlaying: Bool { outstanding > 0 }

    public func play(_ kind: AudioCueKind) {
        guard let buffer = AudioCueSynthesizer.buffer(for: kind) else {
            diagnostics.record("cue.synthesis_failed", level: .warning,
                               fields: ["cue": kind.rawValue])
            return
        }

        if !engineRunning {
            let result = scheduler.start(
                sampleRate: AudioCueSynthesizer.sampleRate, channels: 1)
            switch result {
            case .success:
                engineRunning = true
                scheduler.onConfigurationChange = { [weak self] in
                    self?.handleConfigurationChange()
                }
                diagnostics.record("cue.engine_started")
            case .failure(let failure):
                diagnostics.record("cue.unavailable", level: .warning,
                                   fields: ["cue": kind.rawValue,
                                            "error": failure.description])
                return
            }
        }

        let scheduled = generation
        outstanding += 1
        let result = scheduler.schedule(buffer) { [weak self] in
            self?.cueCompleted(generation: scheduled)
        }
        if case .failure(let failure) = result {
            outstanding -= 1
            diagnostics.record("cue.schedule_failed", level: .warning,
                               fields: ["cue": kind.rawValue,
                                        "error": failure.description])
            stopEngine()
            return
        }
        diagnostics.record("cue.played", fields: ["cue": kind.rawValue])
    }

    /// Abandons any cue in flight. Idempotent.
    public func stop() {
        generation &+= 1
        outstanding = 0
        stopEngine()
    }

    private func cueCompleted(generation completed: UInt64) {
        guard completed == generation, outstanding > 0 else { return }
        outstanding -= 1
        guard outstanding == 0 else { return }
        stopEngine()
    }

    private func handleConfigurationChange() {
        guard engineRunning else { return }
        diagnostics.record("cue.configuration_changed", level: .warning)
        generation &+= 1
        outstanding = 0
        stopEngine()
    }

    private func stopEngine() {
        scheduler.onConfigurationChange = nil
        guard engineRunning else { return }
        engineRunning = false
        if case .failure(let failure) = scheduler.stop() {
            diagnostics.record("cue.stop_failed", level: .warning,
                               fields: ["error": failure.description])
        }
    }
}
#endif
