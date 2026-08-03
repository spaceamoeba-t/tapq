import Foundation
import TapQContracts

/// Presents any `VoiceBackend` as the `VoiceCommandProviding` the arbiter already consumes,
/// so swapping the speech pipe underneath TapQ never reaches the interaction layer.
///
/// The window shape is the one `VoiceListener` established and every composition above
/// depends on: one `start` opens a session and exactly one user turn, the first matched
/// transcript resolves the window and tears it down, and `stop` closes everything. Turns
/// are opened only inside `start`, which is what keeps the microphone from being live
/// between windows no matter which backend is plugged in.
///
/// Every degraded path fails open in the same direction as the rest of the voice channel:
/// a session that cannot be opened, or one that dies mid-window, delivers nothing and
/// stays quiet. The window still resolves by gesture, tap, or timeout — a voice backend
/// must never be able to make a window hang.
@MainActor public final class VoiceBackendCommandProvider: VoiceCommandProviding {
    /// The keyword grammar, injected rather than defaulted.
    ///
    /// `VoiceCommandMatcher` lives in `TapQDetectionBaseline`, and this module deliberately
    /// depends on nothing but `TapQContracts`; composition passes `VoiceCommandMatcher.match`.
    public typealias TranscriptMatching = @MainActor (String) -> VoiceCommand?

    private let backend: any VoiceBackend
    private let match: TranscriptMatching
    private let diagnostics: TapQDiagnosticEmitter

    private var handler: (@MainActor (VoiceCommand) -> Void)?
    private var sessionOpen = false
    private var turnActive = false
    /// Invalidates events and open-completions belonging to an earlier window. A backend
    /// event can always arrive one main-actor hop after the window that asked for it was
    /// torn down; without this, a transcript from a dead window resolves a live one.
    private var windowGeneration: UInt64 = 0

    public init(backend: any VoiceBackend,
                match: @escaping TranscriptMatching,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.backend = backend
        self.match = match
        self.diagnostics = TapQDiagnosticEmitter(category: "VoiceBackend", sink: diagnosticSink)
    }

    var isWindowOpenForTesting: Bool { handler != nil }

    public func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
        guard handler == nil else {
            diagnostics.record("start.skipped", fields: ["reason": "already_running"])
            return
        }
        windowGeneration &+= 1
        let generation = windowGeneration
        handler = onCommand
        // `open` is async by contract (a socket-backed adapter has to await a handshake),
        // so the window opens on the next main-actor turn and every step after the await
        // re-checks that it is still the window that asked.
        Task { @MainActor [weak self] in
            await self?.openWindow(generation: generation)
        }
    }

    public func stop() {
        teardown()
    }

    private func openWindow(generation: UInt64) async {
        do {
            try await backend.open { [weak self] event in
                self?.handle(event, generation: generation)
            }
        } catch {
            guard windowGeneration == generation else { return }
            diagnostics.record("window.open_failed", level: .warning,
                               fields: ["error": Self.describe(error)])
            teardown(expectedGeneration: generation)
            return
        }
        guard windowGeneration == generation else {
            // `stop()` landed while the handshake was still in flight. The session is ours
            // and nobody else will ever close it.
            backend.close()
            return
        }
        sessionOpen = true
        backend.beginUserTurn()
        turnActive = true
        diagnostics.record("window.started")
    }

    private func handle(_ event: VoiceBackendEvent, generation: UInt64) {
        guard windowGeneration == generation else { return }
        switch event {
        case .transcriptPartial(let transcript):
            consume(transcript, isFinal: false, generation: generation)
        case .transcriptFinal(let transcript):
            consume(transcript, isFinal: true, generation: generation)
        case .audio:
            // A command channel has nowhere to put response audio; TapQ speaks through its
            // own engine. Recorded rather than dropped silently so a misconfigured duplex
            // backend is visible in the log.
            diagnostics.record("audio.ignored")
        case .responseCompleted:
            break
        case .sessionFailed(let failure):
            diagnostics.record("session.failed", level: .warning,
                               fields: ["detail": failure.localizedDescription])
            // The session is gone: ending its turn would be a call into a dead backend.
            turnActive = false
            teardown(expectedGeneration: generation)
        }
    }

    /// Transcripts are cumulative for a turn — the whole utterance so far, not a delta —
    /// which is exactly what `VoiceListener.handleRecognition` matches against today, so the
    /// grammar sees the same input it always has.
    private func consume(_ transcript: String, isFinal: Bool, generation: UInt64) {
        guard let command = match(transcript) else {
            if isFinal {
                // The wearer said something the grammar does not know. Logged so a "voice
                // does nothing" report stays diagnosable from the log file alone.
                diagnostics.record("transcript.rejected",
                                   fields: ["reason": "unmatched",
                                            "length": "\(transcript.count)"])
            }
            return
        }
        diagnostics.record("command.matched", fields: ["command": "\(command)"])
        let callback = handler
        teardown(expectedGeneration: generation)
        callback?(command)
    }

    private func teardown(expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != windowGeneration { return }
        windowGeneration &+= 1
        handler = nil
        if turnActive {
            turnActive = false
            backend.endUserTurn()
        }
        if sessionOpen {
            sessionOpen = false
            backend.close()
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? VoiceBackendFailure)?.localizedDescription ?? String(describing: error)
    }
}
