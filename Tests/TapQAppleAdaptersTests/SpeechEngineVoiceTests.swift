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

    // The substitution rule is asserted directly because whether AVFoundation substitutes
    // at all varies by macOS version and installed voice set: the CI runner returns en-US
    // Samantha for "not-a-real-voice" where a local macOS 26 machine returns nil. These
    // hold on any host.

    func testRegionalSubstitutionWithinTheSameLanguageIsAccepted() {
        XCTAssertTrue(SpeechEngine.languageMatches("en-US", requested: "en-GB"))
        XCTAssertTrue(SpeechEngine.languageMatches("en-US", requested: "en"))
        XCTAssertTrue(SpeechEngine.languageMatches("en-US", requested: "EN-us"))
    }

    func testCrossLanguageSubstitutionIsRejected() {
        XCTAssertFalse(SpeechEngine.languageMatches("en-US", requested: "not-a-real-voice"),
                       "the CI substitution that made this suite fail")
        XCTAssertFalse(SpeechEngine.languageMatches("en-US", requested: "zh-CN"))
        XCTAssertFalse(SpeechEngine.languageMatches("en-US", requested: ""))
    }

    // The Samantha preference only applies to selections that mean "English, any voice".
    // The classifier is what guarantees a regional or specific selection is never
    // redirected, so it is asserted directly and host-independently.

    func testGenericEnglishSelectionsAreClassified() {
        XCTAssertTrue(SpeechEngine.isGenericEnglishSelection("en"))
        XCTAssertTrue(SpeechEngine.isGenericEnglishSelection("en-US"))
        XCTAssertTrue(SpeechEngine.isGenericEnglishSelection("EN-us"))
    }

    func testRegionalAndSpecificSelectionsAreNotGeneric() {
        XCTAssertFalse(SpeechEngine.isGenericEnglishSelection("en-GB"),
                       "a regional choice must reach the voice for that region")
        XCTAssertFalse(SpeechEngine.isGenericEnglishSelection("zh-CN"))
        XCTAssertFalse(SpeechEngine.isGenericEnglishSelection("com.apple.eloquence.en-US.Eddy"),
                       "an explicit Eddy pin must still get Eddy")
        XCTAssertFalse(SpeechEngine.isGenericEnglishSelection(""))
    }

    /// Whether a high-tier Samantha is installed varies by host (the CI runner has none;
    /// a machine that ran the download has enhanced). The assertion adapts: with one
    /// installed, the generic selection must resolve to it; the skip records why the
    /// preference went unexercised.
    func testGenericEnglishPrefersDownloadedSamantha() throws {
        let installed = SpeechEngine.preferredEnUSVoiceIdentifiers.first { identifier in
            AVSpeechSynthesisVoice(identifier: identifier)?.identifier == identifier
        }
        guard let expected = installed else {
            throw XCTSkip("no downloadable-tier Samantha on this host; nothing to prefer")
        }
        XCTAssertEqual(SpeechEngine.resolveVoice("en-US")?.identifier, expected)
        XCTAssertEqual(SpeechEngine.resolveVoice("en")?.identifier, expected)
    }

    func testExplicitIdentifierBypassesTheSamanthaPreference() throws {
        let compact = AVSpeechSynthesisVoice.speechVoices().first {
            $0.language == "en-US" && $0.quality == .default
        }
        guard let compact else {
            throw XCTSkip("no compact en-US voice on this host")
        }
        XCTAssertEqual(SpeechEngine.resolveVoice(compact.identifier)?.identifier,
                       compact.identifier,
                       "pinning a specific voice must return exactly that voice")
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
