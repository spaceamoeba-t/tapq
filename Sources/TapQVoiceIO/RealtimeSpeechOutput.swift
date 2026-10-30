import Foundation
import TapQContracts
import TapQKernel
import TapQVoiceBackends

/// Speech out: TapQ's sentences voiced by a dedicated output-only realtime session, one
/// out-of-band response per part, into the player.
///
/// An item is `played` when the player reports its last buffer played back, with
/// `verbatim` the AND over its parts of `VerbatimCheck` against the session's own
/// transcript. Two things restart an item from its start, and the kernel hears nothing of
/// either: a session that expires (D4) is reopened at once, and an item it cut off is
/// flushed; a change of output route flushes the player (D7), which reports the reading
/// `.flushed`. Every other ending of the session, a response that ends
/// `failed`/`incomplete`, a stalled response and a player failure are `failed`: with no
/// voice there is nothing left to report with.
@MainActor public final class RealtimeSpeechOutput: SpeechOutput {
    public nonisolated static let modelEnvironmentKey = "TAPQ_TTS_MODEL"
    public nonisolated static let voiceEnvironmentKey = "TAPQ_TTS_VOICE"
    /// Text longer than this (a read-all) is split at sentence ends into consecutive
    /// responses under one `SpeechID`.
    public nonisolated static let partLimit = 2_000

    /// `TAPQ_TTS_MODEL` (default `gpt-realtime-2.1-mini`) and `TAPQ_TTS_VOICE`.
    public nonisolated static func configuration(environment: [String: String]) -> RealtimeSpeechConfiguration {
        func value(_ key: String) -> String? {
            let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : nil
        }
        return RealtimeSpeechConfiguration(
            model: value(modelEnvironmentKey) ?? RealtimeSpeechConfiguration.defaultModel,
            voice: value(voiceEnvironmentKey) ?? RealtimeSpeechConfiguration.defaultVoice)
    }

    private struct Item {
        let id: SpeechID
        let parts: [String]
        var index = 0
        var transcript: String?
        var verbatim = true
        /// Every part is spoken; the player has been asked to report the drain.
        var draining = false
    }

    private enum Voice {
        case open(RealtimeSpeechSession)
        case reopening
        case dead(String)
    }

    private let makeSession: @MainActor () -> RealtimeSpeechSession
    private let player: any VoiceResponseAudioPlaying
    private let monotonicNow: @MainActor () -> TimeInterval
    private let diagnostics: TapQDiagnosticEmitter
    private let continuation: AsyncStream<SpeechOutputEvent>.Continuation

    public let events: AsyncStream<SpeechOutputEvent>

    private var voice = Voice.dead("the voice was never opened")
    private var item: Item?
    private var cancelled = false

    /// - Parameters:
    ///   - makeSession: a fresh output-only session, at `open()` and at each expiry.
    ///   - monotonicNow: the clock `played(at:)` is stamped on; the capture clock
    ///     (`ProcessInfo.systemUptime`), which the kernel compares `speechStarted.at` with.
    public init(makeSession: @escaping @MainActor () -> RealtimeSpeechSession,
                player: any VoiceResponseAudioPlaying,
                monotonicNow: @escaping @MainActor () -> TimeInterval,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.makeSession = makeSession
        self.player = player
        self.monotonicNow = monotonicNow
        self.diagnostics = TapQDiagnosticEmitter(category: "speech-output", sink: diagnosticSink)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Opens the session at startup and keeps it warm. Throws when it cannot be opened.
    public func open() async throws {
        voice = .reopening
        try await openSession()
    }

    public func speak(_ text: String, id: SpeechID) {
        guard !cancelled else { return }
        continuation.yield(.started(id))
        begin(Item(id: id, parts: Self.parts(of: text)))
    }

    /// Shutdown: cancels the active response by its id, flushes the player, and reports
    /// nothing more.
    public func cancel() {
        cancelled = true
        item = nil
        if case .open(let session) = voice { session.cancel() }
        player.stopAndFlush()
        continuation.finish()
    }

    // MARK: - Session

    private func openSession() async throws {
        let session = makeSession()
        let events = session.events
        Task { @MainActor [weak self] in
            for await event in events {
                guard let self, !self.cancelled else { return }
                self.handle(event, from: session)
            }
        }
        do {
            try await session.open()
        } catch {
            voice = .dead("the voice could not be opened: \(error.localizedDescription)")
            throw error
        }
        voice = .open(session)
    }

    private func handle(_ event: RealtimeSpeechEvent, from session: RealtimeSpeechSession) {
        guard case .open(let current) = voice, current === session else { return }
        switch event {
        case .audio(let audio):
            player.enqueue(VoiceAudioChunk(data: audio, format: .pcm16Mono24k,
                                           timestamp: monotonicNow()))
        case .transcript(let text):
            item?.transcript = text
        case .done:
            finishPart(on: session)
        case .expired:
            rollOver()
        case .failed(let reason):
            voice = .dead(reason)
            if item?.draining == false { failItem(reason) }
        }
    }

    /// D4: reopen now; an item the expiry cut off is flushed and spoken again from its
    /// start once the new session is up.
    private func rollOver() {
        voice = .reopening
        if let cut = item, !cut.draining {
            player.stopAndFlush()
            item = Item(id: cut.id, parts: cut.parts)
        }
        diagnostics.record("session.rollover", fields: ["respeak": item?.draining == false ? "yes" : "no"])
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.openSession()
            } catch {
                if self.item?.draining == false { self.failItem(error.localizedDescription) }
                return
            }
            if case .open(let session) = self.voice, self.item?.draining == false {
                self.speakPart(on: session)
            }
        }
    }

    // MARK: - Parts

    /// Speaks `item` from its first part as soon as the voice is open.
    private func begin(_ item: Item) {
        self.item = item
        switch voice {
        case .open(let session): speakPart(on: session)
        case .reopening: break
        case .dead(let reason): failItem(reason)
        }
    }

    private func speakPart(on session: RealtimeSpeechSession) {
        guard var current = item else { return }
        current.transcript = nil
        item = current
        session.speak(current.parts[current.index])
    }

    private func finishPart(on session: RealtimeSpeechSession) {
        guard var current = item, !current.draining else { return }
        let part = current.parts[current.index]
        let heard = current.transcript ?? ""
        if !VerbatimCheck.isVerbatim(input: part, heard: heard) {
            current.verbatim = false
            diagnostics.record("tts.paraphrase", level: .warning,
                               fields: ["id": "\(current.id.raw)"])
            diagnostics.record("tts.paraphrase.text", level: .debug, fields: [
                "id": "\(current.id.raw)",
                "input": VerbatimCheck.tokens(part).joined(separator: " "),
                "heard": VerbatimCheck.tokens(heard).joined(separator: " "),
            ])
        }
        current.index += 1
        guard current.index == current.parts.count else {
            item = current
            return speakPart(on: session)
        }
        current.draining = true
        item = current
        let id = current.id
        player.finishStream { [weak self] ending in self?.drained(id, ending) }
    }

    private func drained(_ id: SpeechID, _ ending: VoiceResponseStreamEnding) {
        guard !cancelled, let current = item, current.id == id else { return }
        switch ending {
        case .playedBack:
            item = nil
            continuation.yield(.played(id, at: monotonicNow(), verbatim: current.verbatim))
        case .flushed:
            diagnostics.record("speech_output.respeak", fields: ["id": "\(id.raw)"])
            begin(Item(id: id, parts: current.parts))
        case .failed:
            item = nil
            continuation.yield(.failed(id, reason: "the player failed"))
        }
    }

    private func failItem(_ reason: String) {
        guard let current = item else { return }
        item = nil
        diagnostics.record("speech_output.failed", level: .warning, fields: ["detail": reason])
        continuation.yield(.failed(current.id, reason: reason))
    }

    /// Splits text over ``partLimit`` at sentence ends (`.`, `!`, `?` before whitespace,
    /// and line breaks); a sentence longer than the limit is split at its last space
    /// before it. Shorter text is one part, unchanged.
    nonisolated static func parts(of text: String, limit: Int = partLimit) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        var sentence = ""
        var previous: Character?
        for character in text {
            if character.isWhitespace,
               character.isNewline || previous.map({ ".!?".contains($0) }) == true {
                sentences.append(sentence)
                sentence = ""
            }
            sentence.append(character)
            previous = character
        }
        sentences.append(sentence)

        var parts: [String] = []
        var part = ""
        for var sentence in sentences {
            if part.count + sentence.count > limit, !part.isEmpty {
                parts.append(part)
                part = ""
            }
            while sentence.count > limit {
                let window = sentence.prefix(limit)
                let space = window.lastIndex(where: \.isWhitespace)
                let cut = space.flatMap { $0 > window.startIndex ? $0 : nil } ?? window.endIndex
                parts.append(String(sentence[..<cut]))
                sentence = String(sentence[cut...])
            }
            part += sentence
        }
        parts.append(part)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
