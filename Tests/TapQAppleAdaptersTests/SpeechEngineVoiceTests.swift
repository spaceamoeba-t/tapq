import XCTest
@testable import TapQAppleAdapters
import AVFoundation
import TapQContracts

@MainActor
final class SpeechEngineVoiceTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.name)
        }
    }

    func testResolvesBCP47LanguageTag() throws {
        let voice = try XCTUnwrap(SpeechEngine.resolveVoice("en-US"))
        XCTAssertEqual(voice.language, "en-US")
    }

    func testResolvesFullVoiceIdentifier() throws {
        let reference = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let voice = try XCTUnwrap(SpeechEngine.resolveVoice(reference.identifier))
        XCTAssertEqual(voice.identifier, reference.identifier)
    }

    func testUnknownSelectionResolvesToNil() {
        XCTAssertNil(SpeechEngine.resolveVoice("not-a-real-voice"))
    }

    /// An unresolvable selection must be visible: silently falling back to the
    /// system-locale voice is the exact bug this option exists to fix.
    func testUnresolvableSelectionRecordsDiagnostic() {
        let sink = RecordingSink()
        let engine = SpeechEngine(diagnosticSink: sink)
        engine.synthesisForTesting = { _ in }
        engine.voiceSelection = "not-a-real-voice"

        engine.speak("hello", priority: .progress, onFinish: nil)

        XCTAssertTrue(sink.names.contains("voice.unavailable"))
    }

    func testResolvableSelectionRecordsNoWarning() {
        let sink = RecordingSink()
        let engine = SpeechEngine(diagnosticSink: sink)
        engine.synthesisForTesting = { _ in }
        engine.voiceSelection = "en-US"

        engine.speak("hello", priority: .progress, onFinish: nil)

        XCTAssertFalse(sink.names.contains("voice.unavailable"))
    }
}
