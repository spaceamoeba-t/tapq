import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The tool vocabulary and the rules for turning one call into something that happens.
///
/// Everything here is pure, which is the point: the decision that replaced the keyword
/// grammar (2026-08-28) put every judgement about what a call means in one function, so the
/// arguments a model might actually produce — a missing field, a zero index, a name nobody
/// declared — can be enumerated rather than hoped about.
final class VoiceIntentToolsTests: XCTestCase {
    private func call(_ name: String, _ arguments: String = "") -> VoiceToolCall {
        VoiceToolCall(callID: "call_1", name: name, argumentsJSON: arguments)
    }

    // MARK: - The declaration

    /// Five tools, named exactly as the plan of record names them. Pinned because the names
    /// are a contract with a model that has been told about them by description, and a
    /// rename is a silent behavior change rather than a compile error.
    func testTheDeclaredToolSetIsTheFiveRatifiedActions() {
        XCTAssertEqual(VoiceIntentTools.declarations.map(\.name),
                       ["approve", "deny", "select_item", "queue_instruction", "query_status"])
    }

    /// The absence that is the mechanism. No tool ends the voice session, stops listening, or
    /// shuts anything down — that is how "no spoken input may end the session" is enforced on
    /// this path, and a tool added later with any of these meanings would defeat it silently.
    func testNoToolCanEndTheSessionOrTheRuntime() {
        let forbidden = ["end", "stop", "quit", "exit", "shutdown", "kill", "close", "sleep"]
        for declaration in VoiceIntentTools.declarations {
            for word in forbidden {
                XCTAssertFalse(declaration.name.contains(word),
                               "\(declaration.name) reads like a way out of the session")
            }
        }
    }

    /// `approve` and `deny` take nothing. An argument on either would be a field a model
    /// could fill in with a reason, and a reason is a sentence nobody wrote being spoken at
    /// approval priority.
    func testTheTwoAnswersTakeNoArguments() {
        let answers = VoiceIntentTools.declarations
            .filter { $0.name == "approve" || $0.name == "deny" }
        XCTAssertEqual(answers.count, 2)
        for declaration in answers {
            XCTAssertTrue(declaration.parameters.isEmpty)
        }
    }

    /// The agent is optional and the text is not. A model that had to supply an agent would
    /// invent one, which is the routing failure Rung E's fail-closed refusal exists to catch
    /// — better not to manufacture the case at all.
    func testQueueInstructionRequiresTextAndNotTheAgent() {
        guard let declaration = VoiceIntentTools.declarations
            .first(where: { $0.name == "queue_instruction" }) else {
            return XCTFail("queue_instruction is not declared")
        }
        let byName = Dictionary(uniqueKeysWithValues: declaration.parameters.map { ($0.name, $0) })
        XCTAssertEqual(byName["text"]?.required, true)
        XCTAssertEqual(byName["agent"]?.required, false)
    }

    /// `query_status` is a closed set on the wire, so a third kind is refused by the service
    /// before it reaches the executor.
    func testQueryStatusPinsItsTwoKinds() {
        let kind = VoiceIntentTools.declarations
            .first { $0.name == "query_status" }?
            .parameters.first { $0.name == "kind" }
        XCTAssertEqual(kind?.allowedValues, ["waiting", "changed"])
    }

    // MARK: - Execution with a window open

    func testApproveAndDenyResolveToTheTwoAnswers() {
        guard case .command(let allow, _) =
            VoiceIntentTools.resolve(call("approve"), windowOpen: true) else {
            return XCTFail("approve did not resolve to a command")
        }
        XCTAssertEqual(allow, .yes)
        guard case .command(let refuse, _) =
            VoiceIntentTools.resolve(call("deny"), windowOpen: true) else {
            return XCTFail("deny did not resolve to a command")
        }
        XCTAssertEqual(refuse, .no)
    }

    func testSelectItemCarriesTheOneBasedIndex() {
        guard case .command(let command, _) = VoiceIntentTools.resolve(
            call("select_item", #"{"index":3}"#), windowOpen: true) else {
            return XCTFail("select_item did not resolve to a command")
        }
        XCTAssertEqual(command, .number(3))
    }

    /// Zero is a model counting from somewhere TapQ never numbered. Refused rather than
    /// nudged to 1: picking the closest entry is choosing on the wearer's behalf, which is
    /// exactly the guessing this path removed.
    func testSelectItemRefusesAnIndexBelowOne() {
        guard case .refused = VoiceIntentTools.resolve(
            call("select_item", #"{"index":0}"#), windowOpen: true) else {
            return XCTFail("a zero index must be refused")
        }
    }

    func testAnUnaddressedInstructionIsCarriedThroughVerbatim() {
        guard case .command(let command, _) = VoiceIntentTools.resolve(
            call("queue_instruction", #"{"text":"run the tests again"}"#),
            windowOpen: true) else {
            return XCTFail("queue_instruction did not resolve to a command")
        }
        XCTAssertEqual(command, .beginInstruction("run the tests again"))
    }

    /// The address arrives as a structured argument and is written back onto the sentence in
    /// the one form the dictation flow's resolver reads. That flow — read-back, fail-closed
    /// attribution, unknown-agent refusal — is Rung E's, unchanged.
    func testAnAddressedInstructionIsHandedToTheRungEResolver() {
        guard case .command(let command, _) = VoiceIntentTools.resolve(
            call("queue_instruction", #"{"agent":"Codex","text":"run the tests"}"#),
            windowOpen: true) else {
            return XCTFail("an addressed queue_instruction did not resolve to a command")
        }
        XCTAssertEqual(command, .beginInstruction("tell Codex to run the tests"))
        guard case .beginInstruction(.some(let text)) = command else { return }
        XCTAssertEqual(InstructionAddress.parse(text)?.name, "Codex")
        XCTAssertEqual(InstructionAddress.parse(text)?.rest, "run the tests")
    }

    /// A name nothing answers to is not refused here. It is carried to the resolver, which is
    /// the only thing that knows which sessions are live, and which speaks the fail-closed
    /// refusal Rung E shipped.
    func testAnUnknownAgentIsNotRefusedHere() {
        guard case .command(let command, _) = VoiceIntentTools.resolve(
            call("queue_instruction", #"{"agent":"Borges","text":"stop"}"#),
            windowOpen: true) else {
            return XCTFail("an unknown agent must still reach the resolver")
        }
        XCTAssertEqual(command, .beginInstruction("tell Borges to stop"))
    }

    func testQueryStatusMapsOntoTheTwoInformationalIntents() {
        guard case .command(let waiting, _) = VoiceIntentTools.resolve(
            call("query_status", #"{"kind":"waiting"}"#), windowOpen: true) else {
            return XCTFail("query_status waiting did not resolve")
        }
        XCTAssertEqual(waiting, .status)
        guard case .command(let changed, _) = VoiceIntentTools.resolve(
            call("query_status", #"{"kind":"changed"}"#), windowOpen: true) else {
            return XCTFail("query_status changed did not resolve")
        }
        XCTAssertEqual(changed, .whatChanged)
    }

    // MARK: - Nothing listening

    /// The defensive case, and the one the plan names by hand: a call that arrives after the
    /// window it was meant for has gone. Nothing happens, and the model is still answered —
    /// leaving it parked would hang the channel rather than quieten it.
    func testEveryToolIsRefusedWithNoWindowOpen() {
        let calls = [
            call("approve"),
            call("deny"),
            call("select_item", #"{"index":1}"#),
            call("queue_instruction", #"{"text":"ship it"}"#),
            call("query_status", #"{"kind":"waiting"}"#),
        ]
        for one in calls {
            guard case .refused(let output, _) =
                VoiceIntentTools.resolve(one, windowOpen: false) else {
                return XCTFail("\(one.name) acted with no window open")
            }
            XCTAssertFalse(output.isEmpty, "\(one.name) refused without telling the model why")
        }
    }

    /// **Every** refusal a wearer-directed call can produce says something out loud.
    ///
    /// The table is the test. Before 2026-08-28 three of these rows spoke nothing:
    /// `approve`, `deny`, and `select_item` with no window open were answered to the model
    /// and to nobody else, on the reasoning that the window had probably just resolved by
    /// nod and announcing the race would report it to somebody who never saw one. The
    /// audible-refusal decision reversed that — the wearer this path exists for has no
    /// screen, and from where they stand a silent "approve" is indistinguishable from a dead
    /// microphone.
    ///
    /// Written as an exhaustive table rather than one case per method so that a refusal
    /// added later has to be listed here to compile a passing suite: the invariant is about
    /// the *set* of refusals, not about any one of them.
    func testEveryRefusalSpeaksAndAlsoAnswersTheModel() {
        let rows: [(name: String, call: VoiceToolCall, windowOpen: Bool, speech: String)] = [
            ("approve, no window",
             call("approve"), false, VoiceIntentTools.nothingWaitingNotice),
            ("deny, no window",
             call("deny"), false, VoiceIntentTools.nothingWaitingNotice),
            ("select_item, no window",
             call("select_item", #"{"index":1}"#), false,
             VoiceIntentTools.nothingWaitingNotice),
            ("queue_instruction, no window",
             call("queue_instruction", #"{"text":"ship it"}"#), false,
             VoiceIntentTools.notListeningNotice),
            ("query_status, no window",
             call("query_status", #"{"kind":"waiting"}"#), false,
             VoiceIntentTools.notListeningNotice),
            ("select_item, index below one",
             call("select_item", #"{"index":0}"#), true,
             VoiceIntentTools.unnumberedEntryNotice),
            ("queue_instruction, nothing to queue",
             call("queue_instruction", #"{"text":"   "}"#), true,
             VoiceIntentTools.emptyInstructionNotice),
            ("query_status, a status TapQ does not keep",
             call("query_status", #"{"kind":"weather"}"#), true,
             VoiceIntentTools.unknownStatusNotice),
        ]

        for row in rows {
            guard case .refused(let output, let speech) =
                VoiceIntentTools.resolve(row.call, windowOpen: row.windowOpen) else {
                XCTFail("\(row.name) did not refuse")
                continue
            }
            XCTAssertEqual(speech, row.speech, "\(row.name) spoke the wrong sentence")
            XCTAssertFalse(speech.isEmpty, "\(row.name) refused in silence")
            XCTAssertFalse(output.isEmpty,
                           "\(row.name) refused without telling the model why")
            XCTAssertNotEqual(output, speech,
                              "\(row.name): the model's record and the wearer's sentence are "
                                + "written for different readers and must not be the same "
                                + "string")
        }
    }

    /// The two "nothing is listening" situations get different sentences, because the remedy
    /// differs: repeating a dictation is useful, repeating "yes" into the same silence is
    /// not — the wearer needs to know there is nothing to say yes *to*.
    func testAnsweringIntoAGapAndDictatingIntoOneAreDifferentSentences() {
        XCTAssertNotEqual(VoiceIntentTools.nothingWaitingNotice,
                          VoiceIntentTools.notListeningNotice)
        XCTAssertEqual(VoiceIntentTools.nothingWaitingNotice, "Nothing is waiting.")
    }

    // MARK: - Malformed traffic

    /// Fail loud, never fall back. A tool TapQ never declared says the protocol is not the
    /// one TapQ configured, and the alternative to breaking here is guessing which action the
    /// wearer authorized from a name nobody wrote down.
    func testAnUndeclaredToolIsAProtocolFailure() {
        guard case .malformed = VoiceIntentTools.resolve(call("end_session"), windowOpen: true) else {
            return XCTFail("an undeclared tool must be a protocol failure")
        }
    }

    /// The two conditional tools are undeclared by default, so a call for either against a
    /// composition that did not ask for it lands in the same place a name nobody wrote down
    /// does. The gates default closed; nothing here has to remember to turn them off.
    func testTheConditionalToolsAreProtocolFailuresUnlessTheirGateIsOpen() {
        let conditional = [
            call("ask_about_work", #"{"question":"what did you run?"}"#),
            call("start_task", #"{"goal":"run the tests and tell me"}"#),
        ]
        for one in conditional {
            guard case .malformed = VoiceIntentTools.resolve(one, windowOpen: true) else {
                return XCTFail("\(one.name) ran on a composition that never declared it")
            }
        }
        guard case .startTask = VoiceIntentTools.resolve(
            call("start_task", #"{"goal":"run the tests and tell me"}"#),
            windowOpen: true, startTaskDeclared: true) else {
            return XCTFail("start_task must run where a loop is composed")
        }
    }

    func testUnreadableArgumentsAreAProtocolFailure() {
        let broken = [
            call("select_item", "{not json"),
            call("select_item", #"{"index":"three"}"#),
            call("queue_instruction", #"{"agent":"Codex"}"#),
            call("query_status", "{}"),
        ]
        for one in broken {
            guard case .malformed = VoiceIntentTools.resolve(one, windowOpen: true) else {
                return XCTFail("\(one.name) accepted arguments it cannot have understood")
            }
        }
    }

    /// Empty text is a legal call that could not run, not a broken protocol — refused, and
    /// the session survives it.
    func testAnEmptyInstructionIsRefusedRatherThanFatal() {
        guard case .refused = VoiceIntentTools.resolve(
            call("queue_instruction", #"{"text":"   "}"#), windowOpen: true) else {
            return XCTFail("an empty instruction must be refused, not fatal")
        }
    }

    /// A goal that captured silence is the same kind of event, and gets the same sentence:
    /// the wearer spoke, nothing was heard, and there is nothing to say but "say it again".
    func testAnEmptyGoalIsRefusedWithTheSameSentenceAsAnEmptyInstruction() {
        guard case .refused(_, let speak) = VoiceIntentTools.resolve(
            call("start_task", #"{"goal":"   "}"#),
            windowOpen: true, startTaskDeclared: true) else {
            return XCTFail("an empty goal must be refused, not fatal")
        }
        XCTAssertEqual(speak, VoiceIntentTools.emptyInstructionNotice)
    }

    /// A kind outside the declared enum reaches here only if the service let it through.
    /// Refused rather than fatal: the tool is one TapQ declared and the wearer asked a
    /// question, so the recoverable answer is to say which questions exist.
    func testAnUnknownStatusKindIsRefused() {
        guard case .refused = VoiceIntentTools.resolve(
            call("query_status", #"{"kind":"weather"}"#), windowOpen: true) else {
            return XCTFail("an unknown status kind must be refused")
        }
    }
}
