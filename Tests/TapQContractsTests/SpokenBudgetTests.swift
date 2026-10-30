import XCTest
import TapQContracts

/// The spoken budget: when a reply is summarized rather than read, the rule TapQ's own models
/// are given, the offer, and what "read it all" is left holding.
///
/// Nothing here shortens text: there is no cut to test, by design. The store tests are
/// `async` and main-actor because the store is; the rest are plain.
final class SpokenBudgetTests: XCTestCase {
    func testAReplyIsSummarizedOnlyWhenItIsLongerThanTheBudget() {
        XCTAssertEqual(SpokenBudget.characters, 120)
        XCTAssertFalse(SpokenBudget.exceeds(String(repeating: "a", count: 120)))
        XCTAssertTrue(SpokenBudget.exceeds(String(repeating: "a", count: 121)))
    }

    func testTheRuleTheModelsAreGivenStatesTheFigure() {
        XCTAssertTrue(SpokenBudget.promptRule.contains("at most 120 characters"))
    }

    /// The offer follows the summary with a space in Latin text and without one in Chinese,
    /// and it is in the summary's language.
    func testTheOfferFollowsTheSummaryInItsLanguage() {
        XCTAssertEqual(SpokenBudget.withOffer("It finished the migration."),
                       "It finished the migration. Say \"read it all\" for the rest.")
        XCTAssertEqual(SpokenBudget.withOffer("迁移已经完成，全部测试通过。"),
                       "迁移已经完成，全部测试通过。想听完整内容，就说“全部读出来”。")
    }

    /// Han characters count against Latin words, so a Chinese sentence naming a long
    /// identifier stays Chinese and an English one naming a Chinese city stays English.
    func testLanguageIsDecidedByHanCharactersAgainstLatinWords() {
        XCTAssertTrue(SpokenBudget.isChinese("我修改了 VoiceBackendCommandProvider 文件"))
        XCTAssertFalse(SpokenBudget.isChinese("The office in 上海 opens tomorrow morning."))
    }

    // MARK: - The store

    /// A summarized reply holds its original; a reply read in full clears the slot, so "the
    /// rest" is always the rest of the last reply.
    @MainActor
    func testTheStoreHoldsOnlyTheLastSummarizedReply() async {
        let store = HeldReadOutStore()
        XCTAssertNil(store.latest)

        store.hold("The whole reply, exactly as it was written.", source: .agentReply)
        XCTAssertEqual(store.latest, HeldReadOutStore.ReadOut(
            text: "The whole reply, exactly as it was written.", source: .agentReply
        ))

        store.clear()
        XCTAssertNil(store.latest, "a reply read in full leaves nothing to read")
    }
}
