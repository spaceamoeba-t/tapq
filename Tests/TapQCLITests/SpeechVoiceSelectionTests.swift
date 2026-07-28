import XCTest
@testable import TapQCLI

final class SpeechVoiceSelectionTests: XCTestCase {
    /// The default must match the recognizer pin: TapQ's spoken scaffolding is hardcoded
    /// English and `VoiceListener.grammarLocale` is en-US.
    func testDefaultIsEnglish() {
        XCTAssertEqual(SpeechVoiceSelection.defaultSelection, "en-US")
    }

    func testDefaultsToEnglishWhenNothingIsConfigured() {
        XCTAssertEqual(
            SpeechVoiceSelection.resolve(flag: nil, environment: [:]),
            "en-US"
        )
    }

    func testEnvironmentOverridesDefault() {
        XCTAssertEqual(
            SpeechVoiceSelection.resolve(
                flag: nil,
                environment: [SpeechVoiceSelection.environmentKey: "zh-CN"]
            ),
            "zh-CN"
        )
    }

    func testFlagOverridesEnvironment() {
        XCTAssertEqual(
            SpeechVoiceSelection.resolve(
                flag: "ja-JP",
                environment: [SpeechVoiceSelection.environmentKey: "zh-CN"]
            ),
            "ja-JP"
        )
    }

    func testBlankEnvironmentValueFallsBackToDefault() {
        XCTAssertEqual(
            SpeechVoiceSelection.resolve(
                flag: nil,
                environment: [SpeechVoiceSelection.environmentKey: "   "]
            ),
            "en-US"
        )
    }

    func testEnvironmentValueIsTrimmed() {
        XCTAssertEqual(
            SpeechVoiceSelection.resolve(
                flag: nil,
                environment: [SpeechVoiceSelection.environmentKey: " zh-CN\n"]
            ),
            "zh-CN"
        )
    }
}
