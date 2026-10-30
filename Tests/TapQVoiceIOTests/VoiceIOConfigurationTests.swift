import XCTest
import TapQVoiceBackends
@testable import TapQVoiceIO

/// What the composition gets from the environment, and how long items are cut.
final class VoiceIOConfigurationTests: XCTestCase {

    func testTheTranscriptionSessionIsPinned() {
        XCTAssertEqual(
            RealtimeSpeechInput.configuration(environment: [:], language: "en"),
            RealtimeTranscriptionConfiguration(
                model: "gpt-4o-transcribe",
                prompt: "The speaker gives instructions to coding agents named Claude, "
                    + "Claude Code and Codex, and to the chat assistants Claude chat and ChatGPT.",
                language: "en",
                turnDetection: .serverVAD(prefixPaddingMs: 300, silenceDurationMs: 600)))
    }

    func testTheTranscriberComesFromTheEnvironment() {
        let configuration = RealtimeSpeechInput.configuration(
            environment: ["TAPQ_STT_MODEL": " gpt-transcribe "], language: nil)
        XCTAssertEqual(configuration.audio.input.transcription.model, "gpt-transcribe")
        XCTAssertNil(configuration.audio.input.transcription.language)
        XCTAssertEqual(
            RealtimeSpeechInput.configuration(environment: ["TAPQ_STT_MODEL": " "], language: nil)
                .audio.input.transcription.model,
            "gpt-4o-transcribe")
    }

    func testTheVoiceComesFromTheEnvironment() {
        XCTAssertEqual(RealtimeSpeechOutput.configuration(environment: [:]),
                       RealtimeSpeechConfiguration(model: "gpt-realtime-2.1-mini", voice: "cedar"))
        XCTAssertEqual(
            RealtimeSpeechOutput.configuration(environment: ["TAPQ_TTS_MODEL": "gpt-realtime-2.1",
                                                             "TAPQ_TTS_VOICE": "marin"]),
            RealtimeSpeechConfiguration(model: "gpt-realtime-2.1", voice: "marin"))
    }

    // MARK: - Long items

    func testShortTextIsOnePartUnchanged() {
        XCTAssertEqual(RealtimeSpeechOutput.parts(of: "Allowed."), ["Allowed."])
        let exactly = String(repeating: "a", count: RealtimeSpeechOutput.partLimit)
        XCTAssertEqual(RealtimeSpeechOutput.parts(of: exactly), [exactly])
    }

    func testLongTextIsSplitAtSentenceEnds() {
        let sentence = "Claude Code said the build is green and the tests pass. "
        let text = String(repeating: sentence, count: 60).trimmingCharacters(in: .whitespaces)
        let parts = RealtimeSpeechOutput.parts(of: text)

        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.count <= RealtimeSpeechOutput.partLimit })
        XCTAssertTrue(parts.allSatisfy { $0.hasSuffix("pass.") }, "no sentence is cut")
        XCTAssertEqual(parts.joined(separator: " "), text)
    }

    func testLineBreaksAndQuestionsEndSentences() {
        XCTAssertEqual(RealtimeSpeechOutput.parts(of: "One two three?\nFour five six! Seven.",
                                                  limit: 16),
                       ["One two three?", "Four five six!", "Seven."])
    }

    func testASentenceLongerThanThePartIsSplitBetweenWords() {
        let text = "alpha beta gamma delta epsilon zeta"
        let parts = RealtimeSpeechOutput.parts(of: text, limit: 12)

        XCTAssertTrue(parts.allSatisfy { $0.count <= 12 })
        XCTAssertEqual(parts.joined(separator: " "), text)
    }

    func testAWordLongerThanThePartIsCutAtTheLimit() {
        XCTAssertEqual(RealtimeSpeechOutput.parts(of: "abcdefghij", limit: 4),
                       ["abcd", "efgh", "ij"])
    }
}
