import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// What the loop sends and how it reads what comes back.
///
/// The decoding half is where the loop's authority is actually enforced — a tool the lane
/// never declared has to be a protocol failure, not a call that quietly does nothing — so
/// most of this suite is about what is refused.
@MainActor
final class WearerTaskContractTests: XCTestCase {
    func testTheTaskLaneDeclaresExactlyTheSevenToolsThePlanNames() async {
        let names = WearerTaskContract.tools(for: .task).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, [
            "search_memory", "read_transcript", "get_status", "queue_instruction",
            "speak", "ask_wearer", "finish",
        ])
        // The Responses API's flat function shape, not the nested chat-completions one.
        for tool in WearerTaskContract.tools(for: .task) {
            XCTAssertEqual(tool["type"] as? String, "function")
            XCTAssertNotNil(tool["description"] as? String)
            XCTAssertNotNil(tool["parameters"] as? [String: Any])
        }
    }

    func testEveryDeclaredToolDecodesFromTheArgumentsAModelWouldSend() async throws {
        XCTAssertEqual(
            try WearerTaskContract.decode(
                name: "search_memory", argumentsJSON: #"{"query":"the migration"}"#, mode: .task
            ),
            .searchMemory(query: "the migration")
        )
        XCTAssertEqual(
            try WearerTaskContract.decode(
                name: "read_transcript",
                argumentsJSON: #"{"agent":"Codex","query":"tests"}"#,
                mode: .task
            ),
            .readTranscript(agent: "Codex", query: "tests")
        )
        // A parameterless tool decodes whichever way the service spells "no arguments".
        XCTAssertEqual(
            try WearerTaskContract.decode(name: "get_status", argumentsJSON: "", mode: .task),
            .getStatus
        )
        XCTAssertEqual(
            try WearerTaskContract.decode(name: "get_status", argumentsJSON: "{}", mode: .task),
            .getStatus
        )
        XCTAssertEqual(
            try WearerTaskContract.decode(
                name: "queue_instruction",
                argumentsJSON: #"{"agent":"Codex","text":"rerun it"}"#,
                mode: .task
            ),
            .queueInstruction(agent: "Codex", text: "rerun it")
        )
        XCTAssertEqual(
            try WearerTaskContract.decode(
                name: "finish", argumentsJSON: #"{"summary":"All green."}"#, mode: .task
            ),
            .finish(summary: "All green.")
        )
    }

    func testAnOmittedAgentIsNilRatherThanAnEmptyName() async throws {
        XCTAssertEqual(
            try WearerTaskContract.decode(
                name: "read_transcript", argumentsJSON: #"{"query":"tests"}"#, mode: .task
            ),
            .readTranscript(agent: nil, query: "tests")
        )
        // A blank one is the same fact and must not reach the resolver as a name.
        XCTAssertEqual(
            try WearerTaskContract.decode(
                name: "queue_instruction",
                argumentsJSON: #"{"agent":"   ","text":"rerun it"}"#,
                mode: .task
            ),
            .queueInstruction(agent: nil, text: "rerun it")
        )
    }

    func testAnUndeclaredToolIsAProtocolFailure() async {
        XCTAssertThrowsError(try WearerTaskContract.decode(
            name: "approve", argumentsJSON: "{}", mode: .task
        )) { error in
            // Same class as an undeclared realtime tool: the run's voice breaks rather than
            // continuing with a loop that is inventing actions.
            XCTAssertTrue("\(error)".contains("undeclared"), "\(error)")
        }
    }

    func testArgumentsThatWillNotParseAreAProtocolFailure() async {
        XCTAssertThrowsError(try WearerTaskContract.decode(
            name: "finish", argumentsJSON: "not json", mode: .task
        ))
        // A required field that arrived blank is a turn spent saying nothing.
        XCTAssertThrowsError(try WearerTaskContract.decode(
            name: "speak", argumentsJSON: #"{"text":"   "}"#, mode: .task
        ))
        XCTAssertThrowsError(try WearerTaskContract.decode(
            name: "search_memory", argumentsJSON: "{}", mode: .task
        ))
    }

    func testTheRenderedTurnCarriesTheGoalTheHistoryAndTheBudget() async {
        let request = WearerTaskTurnRequest(
            goal: "check whether the tests passed",
            mode: .task,
            steps: [
                WearerTaskStep(tool: "read_transcript", arguments: "Codex, tests",
                               result: "Session history: 385 tests."),
            ],
            stepsRemaining: 4
        )
        let input = WearerTaskContract.input(for: request)
        XCTAssertTrue(input.contains("The wearer's goal, in their own words: check whether "
            + "the tests passed"), input)
        XCTAssertTrue(input.contains("--- step 1: read_transcript(Codex, tests)"), input)
        XCTAssertTrue(input.contains("Session history: 385 tests."), input)
        XCTAssertTrue(input.contains("You have 4 turns left"), input)
    }

    func testAFirstTurnSaysSoRatherThanRenderingAnEmptyHistory() async {
        let input = WearerTaskContract.input(for: WearerTaskTurnRequest(
            goal: "watch the build", mode: .task, steps: [], stepsRemaining: 6
        ))
        XCTAssertTrue(input.contains("You have not called any tools yet."), input)
    }

    func testTheQuestionLaneRendersLikeTheM1AnswerPrompt() async {
        let input = WearerTaskContract.input(for: WearerTaskTurnRequest(
            goal: "what did the tests say?",
            mode: .question,
            agentDisplayName: "Claude Code",
            steps: [],
            stepsRemaining: 3
        ))
        XCTAssertTrue(input.contains("Agent: Claude Code"), input)
        XCTAssertTrue(input.contains("The wearer asked: what did the tests say?"), input)
    }

    func testTheQuestionLaneKeepsTheM1AnswerRules() async {
        // Not the same string as `WorkAnswerContract.instructions` — the lane fetches its own
        // evidence — but the four rules that made an M1 answer trustworthy are all still
        // stated, and a future edit that drops one should fail here.
        let rules = WearerTaskContract.questionInstructions
        XCTAssertTrue(rules.contains("Answer only from what your tools returned"), rules)
        XCTAssertTrue(rules.contains("isn't in what I can see of the session"), rules)
        XCTAssertTrue(rules.contains("Quote technical tokens exactly"), rules)
        XCTAssertTrue(rules.contains("looks like a credential"), rules)
        XCTAssertTrue(rules.contains("spoken aloud word for word"), rules)
    }

    func testExcerptsRenderLikeTheAnswerPromptsHistoryBlock() async {
        let rendered = TranscriptExcerpts.rendered(
            slices: [
                WorkQuestionSlice(index: 3, text: "assistant: ran swift build"),
                WorkQuestionSlice(index: 7, text: "tool: 0 errors"),
            ],
            agentDisplayName: "Claude Code"
        )
        XCTAssertTrue(rendered.contains("Agent: Claude Code"), rendered)
        XCTAssertTrue(rendered.contains("2 excerpts, not necessarily contiguous"), rendered)
        XCTAssertTrue(rendered.contains("--- excerpt 3"), rendered)
        XCTAssertTrue(rendered.contains("--- excerpt 7"), rendered)
        XCTAssertTrue(rendered.hasSuffix("--- end of history"), rendered)
    }
}
