import XCTest
@testable import TapQAppleAdapters

final class VoiceListenerTests: XCTestCase {
    @MainActor
    func testRecognizerPinnedToGrammarLocale() async throws {
        XCTAssertEqual(VoiceListener.grammarLocale.identifier, "en-US")
        let listener = VoiceListener()
        guard let localeID = listener.recognizerLocaleForTesting else {
            throw XCTSkip("SFSpeechRecognizer unavailable for en-US on this machine")
        }
        XCTAssertEqual(localeID.replacingOccurrences(of: "_", with: "-"), "en-US")
    }
}
