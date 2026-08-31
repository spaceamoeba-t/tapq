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
    func testTheTaskLaneDeclaresTheSevenToolsThePlanNamesPlusTheRefusal() async {
        let names = WearerTaskContract.tools(for: .task).compactMap { $0["name"] as? String }
        // The plan's seven, and `cannot_do` — the eighth, added 2026-08-30 so a goal beyond
        // every one of the other seven has an ending of its own.
        XCTAssertEqual(names, [
            "search_memory", "read_transcript", "get_status", "queue_instruction",
            "speak", "ask_wearer", "finish", "cannot_do",
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
        XCTAssertEqual(
            try WearerTaskContract.decode(
                name: "cannot_do",
                argumentsJSON: #"{"spoken":"I can't start agent sessions."}"#,
                mode: .task
            ),
            .cannotDo(spoken: "I can't start agent sessions.")
        )
    }

    /// The refusal is a *task* ending. The question lane keeps its three read-only tools and
    /// its own honest-miss rule, so `cannot_do` is undeclared there and a call for it is the
    /// protocol failure any other undeclared tool would be.
    func testTheRefusalIsATaskEndingAndTheQuestionLaneDoesNotDeclareIt() async {
        let names = WearerTaskContract.tools(for: .question)
            .compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains("cannot_do"), "\(names)")
        XCTAssertThrowsError(try WearerTaskContract.decode(
            name: "cannot_do", argumentsJSON: #"{"spoken":"x"}"#, mode: .question
        ))
        // And an empty sentence is a turn spent saying nothing, like every other required
        // argument on this path.
        XCTAssertThrowsError(try WearerTaskContract.decode(
            name: "cannot_do", argumentsJSON: #"{"spoken":"  "}"#, mode: .task
        ))
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

    /// The prompt half of the 2026-08-30 latency fix. The bounds still allow a second turn,
    /// so what makes one call the *typical* path is this guidance — pin it.
    func testTheQuestionLaneIsToldItsEvidenceIsAlreadyInHandAndToFinishOnTurnOne() async {
        let rules = WearerTaskContract.questionInstructions
        XCTAssertTrue(rules.contains("TapQ has already looked up"), rules)
        XCTAssertTrue(rules.contains("call finish on this first turn"), rules)
        // Still permitted, and named, so a lane whose pre-fetch missed does not guess.
        XCTAssertTrue(rules.contains("Look something up yourself only when"), rules)
        XCTAssertTrue(rules.contains("Never repeat a lookup you were already handed"), rules)
    }

    func testAQuestionTurnCarriesThePreFetchedEvidenceApartFromTheSteps() async {
        let input = WearerTaskContract.input(for: WearerTaskTurnRequest(
            goal: "what did the tests say?",
            mode: .question,
            agentDisplayName: "Claude Code",
            evidence: [
                WearerTaskStep(tool: "read_transcript", arguments: "Claude Code, what did "
                    + "the tests say?", result: "Session history: 385 tests."),
                WearerTaskStep(tool: "search_memory", arguments: "what did the tests say?",
                               result: "Nothing in TapQ's memory matches that."),
            ],
            steps: [],
            stepsRemaining: 3
        ))
        XCTAssertTrue(input.contains("TapQ looked these up for you before your first turn"),
                      input)
        XCTAssertTrue(input.contains("--- read_transcript(Claude Code, what did the tests "
            + "say?)"), input)
        XCTAssertTrue(input.contains("Session history: 385 tests."), input)
        XCTAssertTrue(input.contains("--- search_memory(what did the tests say?)"), input)
        XCTAssertTrue(input.contains("--- end of what was looked up"), input)
        // Not rendered as steps the model took: it did not take them, and a model told it
        // already called a tool will not call it when it should.
        XCTAssertFalse(input.contains("What you have done so far"), input)
        XCTAssertTrue(input.contains("You have not called any tools yourself yet"), input)
    }

    /// The prompt half of the 2026-08-30 refusal fix. A live goal — "start a new session in
    /// Claude Code" — was forwarded verbatim into the session that was already running,
    /// because nothing in the instructions said that goals like it have an ending of their
    /// own. Pin what now does.
    func testTheTaskLaneIsToldToRefuseWhatNoToolReachesRatherThanForwardIt() async {
        let rules = WearerTaskContract.taskInstructions
        XCTAssertTrue(rules.contains("You cannot start, stop, restart, or switch an agent's "
            + "session"), rules)
        XCTAssertTrue(rules.contains("you cannot change TapQ itself"), rules)
        XCTAssertTrue(rules.contains("call cannot_do on your first turn and name the limit"),
                      rules)
        // The spoken exemplar, in the repo's spoken-copy voice: what it cannot do, and what
        // it can, in one sentence.
        XCTAssertTrue(rules.contains("I can't start or stop agent sessions — I can only "
            + "instruct ones already connected."), rules)
        // And the specific misuse that produced the failure.
        XCTAssertTrue(rules.contains("queue_instruction is for work the target agent should "
            + "do"), rules)
        XCTAssertTrue(rules.contains("never a way to relay a goal you could not act on "
            + "yourself"), rules)
        XCTAssertTrue(rules.contains("If you cannot do it, say so with cannot_do."), rules)
        // The tool's own description carries the same line, for a model that reads tools
        // more carefully than prose.
        let cannotDo = WearerTaskContract.tools(for: .task)
            .first { $0["name"] as? String == "cannot_do" }
        let description = try? XCTUnwrap(cannotDo?["description"] as? String)
        XCTAssertEqual(description?.contains("never queue_instruction"), true,
                       description ?? "no cannot_do description")
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
