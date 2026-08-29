import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Name-addressed dictation: "tell Codex to run the tests" inside a window that belongs to
/// somebody else.
///
/// Two claims run through every test here. A sentence with no address behaves exactly as it
/// did before addressing existed — same target, same read-back, same words — and an address
/// that does not resolve to exactly one live agent queues nothing at all. Between them they
/// are the whole safety story: routing can move a sentence, and it can refuse to, and it can
/// never decide anything about the request the window was opened for.
@MainActor
final class InstructionAddressingTests: XCTestCase {
    private typealias FakeSpeech = InstructionDictationTests.FakeSpeech
    private typealias ScriptedArbiter = InstructionDictationTests.ScriptedArbiter
    private typealias Inbox = InstructionDictationTests.Inbox

    /// Stands in for the runtime's roster. Deliberately a dictionary and a flag rather than
    /// the real ``AgentRoster``: what is under test here is what the *flow* does with each
    /// of the three answers, and a fake that can produce all three on demand proves that
    /// without also re-testing liveness arithmetic.
    @MainActor
    final class Roster {
        /// Spoken name → (display name, whether the adapter can be instructed).
        var agents: [String: (display: String, instructable: Bool)] = [
            "codex": (display: "Codex", instructable: true),
            "claude": (display: "Claude Code", instructable: true),
        ]
        /// Spoken names that name more than one live session.
        var ambiguous: Set<String> = []
        /// What was routed where, newest last.
        var queued: [(agent: String, text: String)] = []
        /// What the routed mailbox reports back about the sentence it just took.
        var outcome: InstructionQueueOutcome = .queued
        private(set) var namesAsked: [String] = []

        var resolver: InstructionAddressResolving {
            { [self] name in
                namesAsked.append(name)
                let key = name.lowercased()
                if ambiguous.contains(key) {
                    return .ambiguous(agentDisplayName: agents[key]?.display ?? name)
                }
                guard let agent = agents[key] else { return nil }
                return .resolved(
                    InstructionAddressee(
                        agentDisplayName: agent.display,
                        acceptsInstructions: agent.instructable,
                        enqueue: { [self] text in
                            queued.append((agent: agent.display, text: text))
                            return outcome
                        }
                    )
                )
            }
        }
    }

    private func request() -> ApprovalRequest {
        ApprovalRequest(id: "1", sessionID: "s1", agent: .claudeCode, toolName: "Bash",
                        summary: "run npm test", detail: "full detail")
    }

    private func controller(
        _ script: [InputIntent?],
        speech: FakeSpeech,
        inbox: Inbox,
        roster: Roster?
    ) -> InteractionController {
        InteractionController(
            speech: speech,
            arbiter: ScriptedArbiter(script),
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue,
            instructionAddressResolver: roster?.resolver
        )
    }

    // MARK: - The grammar

    func testTellAgentToCapturesTheNameAndTheRest() async {
        let parsed = InstructionAddress.parse("tell Codex to run the tests")
        XCTAssertEqual(parsed?.name, "Codex")
        XCTAssertEqual(parsed?.rest, "run the tests")
    }

    /// A colon is what a recognizer punctuates an address with, and a bare name with no
    /// separator is what a wearer says when they are in a hurry. Both read as one word of
    /// name and the rest as the instruction.
    func testTheColonAndBareFormsParseTheSameWay() async {
        XCTAssertEqual(InstructionAddress.parse("tell Codex: run the tests")?.rest,
                       "run the tests")
        XCTAssertEqual(InstructionAddress.parse("tell Codex: run the tests")?.name, "Codex")
        XCTAssertEqual(InstructionAddress.parse("tell Codex run the tests")?.name, "Codex")
        XCTAssertEqual(InstructionAddress.parse("tell Codex run the tests")?.rest,
                       "run the tests")
    }

    /// A display name that is two words is still one name.
    func testAMultiWordNameIsTakenUpToTheSeparator() async {
        let parsed = InstructionAddress.parse("tell Claude Code to open a pull request")
        XCTAssertEqual(parsed?.name, "Claude Code")
        XCTAssertEqual(parsed?.rest, "open a pull request")
    }

    /// The wearer's own words survive the parse, for the reason the dictation grammar keeps
    /// them: a language model is going to read this, and "readme" is not "README".
    func testTheInstructionKeepsItsCasingAndPunctuation() async {
        XCTAssertEqual(
            InstructionAddress.parse("Tell Codex to update the README, then push.")?.rest,
            "update the README, then push."
        )
    }

    /// Every shape that is not an address. These are the sentences a wearer has always
    /// dictated, and each of them must stay unaddressed rather than become a refusal.
    func testSentencesThatAreNotAddressesParseToNothing() async {
        for text in ["run the tests again",
                     "tell it to run the tests",
                     "tell me what changed",
                     "tell the agent to stop after this file",
                     "tell them to wait",
                     "tell Codex",
                     "tell Codex to"] {
            XCTAssertNil(InstructionAddress.parse(text), text)
        }
    }

    /// Anchored at the start and nowhere else: an instruction is allowed to contain the
    /// word "tell", and cutting one in half at the second occurrence would deliver a
    /// fragment.
    func testAnAddressIsOnlyReadAtTheStartOfTheSentence() async {
        XCTAssertNil(InstructionAddress.parse("ask Claude Code to tell Codex to stop"))
    }

    // MARK: - Routing through the window

    func testAnAddressedDictationIsQueuedForTheNamedAgent() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let roster = Roster()
        let controller = self.controller(
            [.beginInstruction("tell Codex to run the tests"), .allow, .deny],
            speech: speech, inbox: inbox, roster: roster
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(roster.queued.map(\.text), ["run the tests"],
                       "the address is stripped before the agent ever sees it")
        XCTAssertEqual(roster.queued.map(\.agent), ["Codex"])
        XCTAssertEqual(inbox.queued, [], "and nothing reached the window's own session")
        XCTAssertEqual(decision, .deny, "the request is answered by the input after the flow")
    }

    /// RD-era read-backs named the window's agent because there was only ever one. A routed
    /// dictation must name the agent it is actually going to, in both sentences the wearer
    /// hears.
    func testTheReadBackAndTheNoticeNameTheResolvedAgent() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let controller = self.controller(
            [.beginInstruction("tell Codex to run the tests"), .allow, .deny],
            speech: speech, inbox: inbox, roster: Roster()
        )
        _ = await controller.resolve(request())

        XCTAssertTrue(speech.said(containing: "Instruction: 'run the tests.'"),
                      "the wearer confirms the sentence the agent will receive")
        XCTAssertTrue(speech.said(containing: "Queued for Codex."))
        XCTAssertFalse(speech.said(containing: "Queued for Claude Code."))
    }

    /// The unchanged path, pinned as a whole sentence: with a resolver composed, a sentence
    /// carrying no address is queued where it always was, under the name it always had.
    func testAnUnaddressedDictationIsUntouchedByTheResolver() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let roster = Roster()
        let controller = self.controller(
            [.beginInstruction("run the tests again"), .allow, .deny],
            speech: speech, inbox: inbox, roster: roster
        )
        _ = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, ["run the tests again"])
        XCTAssertEqual(roster.queued.count, 0)
        XCTAssertEqual(roster.namesAsked, [], "the resolver was never even consulted")
        XCTAssertTrue(speech.said(containing: "Queued for Claude Code."))
    }

    // MARK: - Fail closed

    /// A name nothing answers to. It is refused rather than delivered to the window's own
    /// agent: the wearer named someone, and quietly sending their sentence elsewhere is the
    /// one outcome they cannot hear and correct.
    func testAnUnknownAgentIsRefusedAndQueuesNothing() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let roster = Roster()
        let controller = self.controller(
            [.beginInstruction("tell Aider to run the tests"), .allow, .deny],
            speech: speech, inbox: inbox, roster: roster
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [])
        XCTAssertEqual(roster.queued.count, 0)
        XCTAssertTrue(speech.said(containing: "I don't know an agent called Aider"))
        XCTAssertEqual(decision, .allow, "and the refusal did not answer the request")
    }

    /// The guard, spoken. Two live sessions answer to the name, so TapQ refuses the routing
    /// and says where the addressee *is* unambiguous.
    func testAnAmbiguousAgentIsRefusedWithTheReasonSaidOutLoud() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let roster = Roster()
        roster.ambiguous = ["claude"]
        let controller = self.controller(
            [.beginInstruction("tell Claude to run the tests"), .allow, .deny],
            speech: speech, inbox: inbox, roster: roster
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [])
        XCTAssertEqual(roster.queued.count, 0)
        XCTAssertTrue(speech.said(
            containing: "More than one Claude Code session is active"
        ))
        XCTAssertEqual(decision, .allow)
    }

    /// RC6 follows the addressee. Cursor has no turn boundary to deliver into, and a
    /// name-route to it is refused in the same words an in-window dictation there would
    /// have heard.
    func testARouteToAnAgentThatCannotBeInstructedIsRefusedByName() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let roster = Roster()
        roster.agents["cursor"] = (display: "Cursor", instructable: false)
        let controller = self.controller(
            [.beginInstruction("tell Cursor to run the tests"), .allow, .deny],
            speech: speech, inbox: inbox, roster: roster
        )
        _ = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [])
        XCTAssertEqual(roster.queued.count, 0)
        XCTAssertTrue(speech.said(containing: "Instructions aren't supported for Cursor."))
    }

    /// Without a resolver — every composition that predates addressing — the address is not
    /// even looked for, and the sentence is queued whole exactly as it used to be.
    func testWithoutAResolverTheAddressIsJustWords() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let controller = self.controller(
            [.beginInstruction("tell Codex to run the tests"), .allow, .deny],
            speech: speech, inbox: inbox, roster: nil
        )
        _ = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, ["tell Codex to run the tests"])
        XCTAssertTrue(speech.said(containing: "Queued for Claude Code."))
    }

    // MARK: - Decisions are not routable

    /// The separation this feature must not weaken. Every intent that resolves a request is
    /// answered by the window, never by the dictation flow, so nothing the wearer says
    /// about another agent can allow, deny, or select in this one — and the confirming
    /// "yes" inside a routed read-back is spent there, exactly as it is for an unaddressed
    /// dictation.
    func testAddressedDictationCannotResolveTheRequest() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let roster = Roster()
        let controller = self.controller(
            [.beginInstruction("tell Codex to deploy"), .allow, .deny],
            speech: speech, inbox: inbox, roster: roster
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(decision, .deny,
                       "the allow that confirmed the read-back never reached the request")
        XCTAssertEqual(roster.queued.map(\.text), ["deploy"])
    }

    /// A refused route leaves the window exactly where it was: still waiting for the answer
    /// it opened for, with its budget spent only on the turns that were taken.
    func testARefusedRouteLeavesTheRequestWaiting() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let arbiter = ScriptedArbiter(
            [.beginInstruction("tell Aider to deploy"), .allow]
        )
        let controller = InteractionController(
            speech: speech,
            arbiter: arbiter,
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue,
            instructionAddressResolver: Roster().resolver
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(arbiter.calls, 2, "the refusal cost one turn, not the window")
    }

    // MARK: - Composing an address back onto a sentence

    /// The round trip that lets a model-backed backend reach Rung E without a second copy of
    /// the dictation flow. `queue_instruction` reports the agent as a structured argument;
    /// `compose` writes it back into the one form `parse` reads; the resolver, the read-back,
    /// the fail-closed attribution check, and the unknown-agent refusal are then the ones that
    /// already shipped. Nothing here reads a transcript — the name came from a tool argument.
    func testComposeIsTheInverseOfParse() async {
        let cases = [
            (name: "Codex", rest: "run the tests"),
            (name: "Claude Code", rest: "explain the diff"),
            (name: "Aider", rest: "tell it to stop"),
        ]
        for (name, rest) in cases {
            let composed = InstructionAddress.compose(name: name, rest: rest)
            guard let parsed = InstructionAddress.parse(composed) else {
                return XCTFail("compose produced a sentence parse does not read: \(composed)")
            }
            XCTAssertEqual(parsed.name, name)
            XCTAssertEqual(parsed.rest, rest)
        }
    }

    /// A composed address is only ever an address. The pronouns that make "tell it to …"
    /// unaddressed are never agent names, so composing can never manufacture one.
    func testComposeNeverProducesAnUnaddressedSentence() async {
        for pronoun in InstructionAddress.unaddressed {
            let composed = InstructionAddress.compose(name: pronoun, rest: "stop")
            XCTAssertNil(InstructionAddress.parse(composed),
                         "\(pronoun) must stay unaddressed")
        }
    }
}
