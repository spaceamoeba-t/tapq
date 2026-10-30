import Foundation

/// Exactly-zero input for longer than any real microphone produces it.
///
/// A quiet hall still has a noise floor; a run of chunks whose every sample is
/// zero is not quiet, it is a microphone that is not connected to the room: access denied
/// by the system (which hands a process silence, not an error), an input muted at the
/// hardware, or Apple's voice-processing unit on an engine with no output side. The watch
/// is pure state: the owner feeds it each chunk and crashes when it trips.
public struct DigitalSilenceWatch: Sendable, Equatable {
    /// Five seconds. Long enough that no pause between sentences reaches it, short enough
    /// that a recording recorded into nothing is stopped while the student is still in the room.
    ///
    /// A floor, not a stopwatch: `silentFor` accumulates `Double` durations, and a block
    /// length that is not a binary fraction (a tenth of a second is not) can leave the sum
    /// a few ulps short, so the trip may land one block later than the arithmetic suggests.
    /// One block of slack on a five-second death is not worth a fixed-point count.
    public static let defaultLimit: TimeInterval = 5

    public let limit: TimeInterval
    /// How long the current run of exactly-zero chunks has lasted. Reset by any chunk that
    /// carries a nonzero byte, and it keeps counting past `limit` — the trip is reported
    /// once, the measurement stays true.
    public private(set) var silentFor: TimeInterval = 0
    public private(set) var tripped = false

    public init(limit: TimeInterval = DigitalSilenceWatch.defaultLimit) {
        self.limit = limit
    }

    /// Returns `true` exactly once: on the chunk that carries the silent run past `limit`.
    /// A chunk is silent when every byte of its PCM16 payload is zero — judged on the bytes
    /// that go on the wire, not on a level read upstream of the converter, because a
    /// converter can turn a whisper of float noise into exact zeros and that is what happened.
    /// A chunk with no duration (`durationSeconds` nil or 0) says nothing and is ignored.
    public mutating func observe(_ chunk: VoiceAudioChunk) -> Bool {
        let seconds = chunk.durationSeconds ?? 0
        guard seconds > 0 else { return false }
        let silent = chunk.data.allSatisfy { $0 == 0 }
        guard silent else {
            silentFor = 0
            return false
        }
        silentFor += seconds
        guard !tripped, silentFor >= limit else { return false }
        tripped = true
        return true
    }
}
