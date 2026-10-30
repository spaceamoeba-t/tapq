import Foundation
import TapQKernel
import XCTest
@testable import TapQKernelCodex

@MainActor
final class CodexDelegateTests: XCTestCase {
    private typealias F = CodexFixtures

    private let workspace = URL(fileURLWithPath: "/work/project")
    private var channel = FakeChannel()
    private var spawned: CodexLaunchSpec?
    private var persisted: [String] = []
    /// Held for the test's length: the delegate's reader holds it weakly, as the kernel's
    /// ownership does in the product.
    private var delegate: CodexDelegate?

    private static let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tapq","title":"TapQ","version":"1.2.3"},"capabilities":{"experimentalApi":false,"requestAttestation":false,"optOutNotificationMethods":["item/agentMessage/delta","item/commandExecution/outputDelta","item/fileChange/outputDelta","item/plan/delta","item/reasoning/summaryPartAdded","item/reasoning/summaryTextDelta","item/reasoning/textDelta","rawResponseItem/completed","turn/diff/updated"]}}}"#
    private static let initialized = #"{"method":"initialized"}"#
    private static let accountRead = #"{"id":2,"method":"account/read","params":{}}"#
    private static let threadStart = #"{"id":3,"method":"thread/start","params":{"cwd":"/work/project","approvalPolicy":"on-request","sandbox":"workspace-write","approvalsReviewer":"user"}}"#

    private static func turnStart(id: Int, _ text: String) -> String {
        #"{"id":\#(id),"method":"turn/start","params":{"threadId":"\#(F.threadID)","input":[{"type":"text","text":"\#(text)","text_elements":[]}]}}"#
    }

    private static func steer(id: Int, _ text: String) -> String {
        #"{"id":\#(id),"method":"turn/steer","params":{"threadId":"\#(F.threadID)","input":[{"type":"text","text":"\#(text)","text_elements":[]}],"expectedTurnId":"\#(F.turnID)"}}"#
    }

    private func makeDelegate(allowsUnsupportedVersion: Bool = false, model: String? = nil,
                              reviewer: CodexApprovalsReviewer = .user) -> CodexDelegate {
        channel.replies = [
            "initialize": F.initialize(),
            "account/read": F.accountChatGPT,
            "thread/start": F.thread(),
            "thread/resume": F.thread(),
        ]
        let configuration = CodexDelegate.Configuration(
            workspace: workspace, executablePath: "/usr/local/bin/codex", clientVersion: "1.2.3",
            model: model, allowsUnsupportedVersion: allowsUnsupportedVersion, reviewer: reviewer)
        let delegate = CodexDelegate(
            configuration: configuration,
            environment: ["PATH": "/usr/bin", "OPENAI_API_KEY": "test-key", "TAPQ_OPENAI_API_KEY": "test-key"],
            spawn: { [unowned self] spec in
                spawned = spec
                return channel
            })
        self.delegate = delegate
        return delegate
    }

    private func start(_ delegate: CodexDelegate, _ session: DelegateSession = .fresh) async throws {
        try await delegate.start(session) { persisted.append($0) }
    }

    /// Started, with turn `F.turnID` active; the next TapQ request id is 5.
    private func working() async throws -> (CodexDelegate, EventRecorder) {
        let delegate = makeDelegate()
        let recorder = EventRecorder(delegate.events)
        try await start(delegate)
        try delegate.send("run the tests")
        channel.feed(F.turnStartResult(id: 4))
        channel.feed(F.turnStarted())
        // A notification that emits, so the turn id has certainly been adopted.
        channel.feed(F.commandStarted)
        await eventually { recorder.events.count == 1 }
        return (delegate, recorder)
    }

    // MARK: - Handshake

    func testFreshStartHandshakesThenPersistsTheThreadBeforeReturning() async throws {
        let delegate = makeDelegate()
        try await start(delegate)

        XCTAssertEqual(channel.written, [Self.initialize, Self.initialized, Self.accountRead, Self.threadStart])
        XCTAssertEqual(persisted, [F.threadID])
        XCTAssertEqual(spawned?.arguments, ["app-server"])
        XCTAssertEqual(spawned?.environment, ["PATH": "/usr/bin"])
    }

    func testResumeSendsThreadResumeWithThePolicy() async throws {
        let delegate = makeDelegate()
        try await start(delegate, .resume(id: F.threadID))

        XCTAssertEqual(channel.written.last, #"{"id":3,"method":"thread/resume","params":{"threadId":"\#(F.threadID)","cwd":"/work/project","approvalPolicy":"on-request","sandbox":"workspace-write","approvalsReviewer":"user","excludeTurns":true}}"#)
        XCTAssertEqual(persisted, [F.threadID])
    }

    func testTheConfiguredModelIsSentOnStartAndOnResume() async throws {
        try await start(makeDelegate(model: "gpt-5.6-luna"))
        XCTAssertEqual(channel.written.last, #"{"id":3,"method":"thread/start","params":{"cwd":"/work/project","model":"gpt-5.6-luna","approvalPolicy":"on-request","sandbox":"workspace-write","approvalsReviewer":"user"}}"#)

        channel = FakeChannel()
        try await start(makeDelegate(model: "gpt-5.6-luna"), .resume(id: F.threadID))
        XCTAssertEqual(channel.written.last, #"{"id":3,"method":"thread/resume","params":{"threadId":"\#(F.threadID)","cwd":"/work/project","model":"gpt-5.6-luna","approvalPolicy":"on-request","sandbox":"workspace-write","approvalsReviewer":"user","excludeTurns":true}}"#)
    }

    func testTheModelIsLunaUnlessTheEnvironmentNamesAnother() async {
        XCTAssertEqual(CodexDelegate.resolvedModel(environment: [:]), "gpt-5.6-luna")
        XCTAssertEqual(CodexDelegate.resolvedModel(environment: ["TAPQ_CODEX_MODEL": " gpt-6-astra "]), "gpt-6-astra")
        XCTAssertEqual(CodexDelegate.resolvedModel(environment: ["TAPQ_CODEX_MODEL": ""]), "gpt-5.6-luna")
    }

    func testResumeThatReturnsAnotherThreadIsAViolation() async throws {
        let delegate = makeDelegate()
        channel.replies["thread/resume"] = F.thread(id: "other")
        await assertStartThrows(delegate, .violation("thread/resume of \(F.threadID) returned thread other"),
                                session: .resume(id: F.threadID))
        XCTAssertEqual(persisted, [])
    }

    func testUnsupportedServerVersionRefusesWithTheRange() async throws {
        let delegate = makeDelegate()
        channel.replies["initialize"] = F.initialize(version: "0.162.0")
        await assertStartThrows(delegate, .unsupportedVersion(
            "Codex 0.162.0 is not supported. TapQ supports 0.161.0 through 0.161.x."))
        XCTAssertEqual(channel.written, [Self.initialize])
    }

    func testVersionOverrideAcceptsAnUnsupportedServer() async throws {
        let delegate = makeDelegate(allowsUnsupportedVersion: true)
        channel.replies["initialize"] = F.initialize(version: "0.162.0")
        try await start(delegate)
        XCTAssertEqual(persisted, [F.threadID])
    }

    func testNotLoggedInRefusesStart() async throws {
        let delegate = makeDelegate()
        channel.replies["account/read"] = F.accountNone
        await assertStartThrows(delegate, .notLoggedIn)
        XCTAssertEqual(CodexDelegateError.notLoggedIn.description, "Codex is not logged in; run `codex login`")
        XCTAssertEqual(channel.written, [Self.initialize, Self.initialized, Self.accountRead])
    }

    /// `--auto-mode` (2026-10-12): Codex's own reviewer, asked for and asserted in the echo.
    func testAutoModeAsksForCodexsReviewerAndChecksTheEcho() async throws {
        let auto = F.thread().replacingOccurrences(of: #""approvalsReviewer":"user""#,
                                                   with: #""approvalsReviewer":"auto_review""#)
        var delegate = makeDelegate(reviewer: .autoReview)
        channel.replies["thread/start"] = auto
        channel.replies["thread/resume"] = auto
        try await start(delegate)
        XCTAssertEqual(channel.written.last, #"{"id":3,"method":"thread/start","params":{"cwd":"/work/project","approvalPolicy":"on-request","sandbox":"workspace-write","approvalsReviewer":"auto_review"}}"#)

        channel = FakeChannel()
        delegate = makeDelegate(reviewer: .autoReview)
        channel.replies["thread/resume"] = auto
        try await start(delegate, .resume(id: F.threadID))
        XCTAssertEqual(channel.written.last, #"{"id":3,"method":"thread/resume","params":{"threadId":"\#(F.threadID)","cwd":"/work/project","approvalPolicy":"on-request","sandbox":"workspace-write","approvalsReviewer":"auto_review","excludeTurns":true}}"#)

        channel = FakeChannel()
        delegate = makeDelegate(reviewer: .autoReview)
        await assertStartThrows(delegate, .violation(
            #"Codex did not apply TapQ's approval policy (on-request, auto_review, workspaceWrite); it reported "on-request", "user", "workspaceWrite""#))
    }

    /// UNSTABLE in 0.161.0: only a denial and Codex's own warning are told.
    func testAutoReviewDenialsAndGuardianWarningsAreTold() async throws {
        let (_, recorder) = try await working()
        let thread = F.threadID
        func review(_ status: String) -> String {
            #"{"method":"item/autoApprovalReview/completed","params":{"threadId":"\#(thread)","turnId":"t","reviewId":"r","startedAtMs":1,"completedAtMs":2,"decisionSource":"agent","targetItemId":null,"action":{"type":"command"},"review":{"status":"\#(status)","riskLevel":"high","rationale":"downloads and runs a script","userAuthorization":null}}}"#
        }
        let before = recorder.events.count
        channel.feed(review("approved"))
        channel.feed(review("timedOut"))
        channel.feed(review("denied"))
        channel.feed(#"{"method":"guardianWarning","params":{"threadId":"\#(thread)","message":"This command would delete files outside the workspace"}}"#)
        await eventually { recorder.events.count == before + 2 }
        XCTAssertEqual(Array(recorder.events.suffix(2)), [
            .notice("Codex's auto-review blocked one of its actions."),
            .notice("Codex warns: This command would delete files outside the workspace."),
        ])
    }

    func testPolicyEchoMismatchIsAViolation() async throws {
        let delegate = makeDelegate()
        channel.replies["thread/start"] = F.thread(approvalPolicy: "never")
        await assertStartThrows(delegate, .violation(
            #"Codex did not apply TapQ's approval policy (on-request, user, workspaceWrite); it reported "never", "user", "workspaceWrite""#))
        XCTAssertEqual(persisted, [])
    }

    func testAPersistThrowAbortsStart() async throws {
        struct DiskFull: Error {}
        let delegate = makeDelegate()
        do {
            try await delegate.start(.fresh) { _ in throw DiskFull() }
            XCTFail("start returned")
        } catch {
            XCTAssertTrue(error is DiskFull)
        }
        XCTAssertThrowsError(try delegate.send("hi"))
    }

    func testAnErrorResponseDuringTheHandshakeFailsStart() async throws {
        let delegate = makeDelegate()
        channel.replies["thread/start"] = #""error":{"code":-32600,"message":"Not initialized"}"#
        await assertStartThrows(delegate, .rejected(method: "thread/start", message: "Not initialized"))
    }

    // MARK: - Turns

    func testSendStartsATurnThenSteersIt() async throws {
        let (delegate, _) = try await working()
        XCTAssertEqual(channel.written[4], Self.turnStart(id: 4, "run the tests"))

        try delegate.send("also update the README")
        XCTAssertEqual(channel.written.last, Self.steer(id: 5, "also update the README"))
    }

    func testInputWaitsForTheTurnIDOfAStartingTurn() async throws {
        let delegate = makeDelegate()
        try await start(delegate)
        try delegate.send("one")
        try delegate.send("two")
        XCTAssertEqual(channel.written.count, 5)

        channel.feed(F.turnStartResult(id: 4))
        await eventually { channel.written.count == 6 }
        XCTAssertEqual(channel.written.last, Self.steer(id: 5, "two"))
    }

    func testSteerRefusedForNoActiveTurnStartsTheTurnOnce() async throws {
        let (delegate, recorder) = try await working()
        try delegate.send("and the docs")
        channel.feed(F.turnCompleted("completed"))
        channel.feed(#"{"id":5,"error":{"code":-32600,"message":"no active turn to steer"}}"#)

        await eventually { channel.written.count == 7 }
        XCTAssertEqual(channel.written.last, Self.turnStart(id: 6, "and the docs"))
        XCTAssertEqual(recorder.events, [.progress("running npm test", step: "item-cmd"), .finished(text: "")])
    }

    /// A live turn that refuses the words keeps working; the user is told, nothing crashes.
    func testASteerRefusedByALiveTurnIsToldAndTheTurnGoesOn() async throws {
        let (delegate, recorder) = try await working()
        try delegate.send("and the docs")
        channel.feed(#"{"id":5,"error":{"code":-32600,"message":"cannot steer a review turn","data":{"message":"cannot steer a review turn","codexErrorInfo":{"activeTurnNotSteerable":{"turnKind":"review"}},"additionalDetails":null,"misalignment":null}}}"#)
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .notice(
            "Codex couldn't take that while it works: cannot steer a review turn. Say it again when it's done."))

        channel.feed(F.turnCompleted("completed"))
        await eventually { recorder.events.count == 3 }
        XCTAssertEqual(recorder.events.last, .finished(text: ""))
    }

    /// The race messages and -32600 are 0.161.0's, seen live; only -32600 counts.
    func testTurnRacesAreReadFromCodeAndWording() async throws {
        for message in ["no active turn to steer", "No active turn to interrupt", "NO ACTIVE TURN"] {
            XCTAssertEqual(CodexMapper.race(code: -32600, message: message, info: nil), .noActiveTurn, message)
        }
        XCTAssertEqual(CodexMapper.race(code: -32600, message: "expected active turn id a but found b", info: nil),
                       .otherTurn("b"))
        XCTAssertEqual(CodexMapper.race(code: -32600, message: "expected active turn id a", info: nil),
                       .otherTurn(nil))
        XCTAssertNil(CodexMapper.race(code: -32603, message: "no active turn", info: nil))
        XCTAssertNil(CodexMapper.race(code: -32600, message: "thread has no active turn", info: nil))
        XCTAssertNil(CodexMapper.race(code: -32600, message: "cannot steer a review turn", info: nil))
        XCTAssertNil(CodexMapper.race(code: -32600, message: "no active turn to steer",
                                      info: "activeTurnNotSteerable"))
    }

    /// A refused `turn/start` is a failed turn (D6), and the next words start a new one.
    func testARefusedTurnStartFailsTheTurnAndFreesInput() async throws {
        let delegate = makeDelegate()
        let recorder = EventRecorder(delegate.events)
        try await start(delegate)
        try delegate.send("one")
        try delegate.send("two")
        channel.feed(#"{"id":4,"error":{"code":-32600,"message":"input must not be empty"}}"#)
        await eventually { recorder.events.count == 1 }
        XCTAssertEqual(recorder.events, [.failed(reason: "input must not be empty")])

        try delegate.send("three")
        XCTAssertEqual(channel.written.last, Self.turnStart(id: 5, "three"))
    }

    /// TapQ's turn id is stale: the words go as `turn/start`, which steers the live turn, and
    /// the turn it names is adopted, so later words steer it.
    func testASteerForAStaleTurnIsResentAndTheLiveTurnAdopted() async throws {
        let (delegate, recorder) = try await working()
        try delegate.send("and the docs")
        channel.feed(#"{"id":5,"error":{"code":-32600,"message":"expected active turn id \#(F.turnID) but found t2"}}"#)
        await eventually { channel.written.count == 7 }
        XCTAssertEqual(channel.written.last, Self.turnStart(id: 6, "and the docs"))

        channel.feed(F.turnStartResult(id: 6, turn: "t2"))
        // A notification that emits, so the result has certainly been handled.
        channel.feed(F.commandStarted)
        await eventually { recorder.events.count == 2 }
        try delegate.send("and the tests")
        XCTAssertEqual(channel.written.last,
                       #"{"id":7,"method":"turn/steer","params":{"threadId":"\#(F.threadID)","input":[{"type":"text","text":"and the tests","text_elements":[]}],"expectedTurnId":"t2"}}"#)
    }

    func testAnInterruptForAStaleTurnInterruptsTheLiveOne() async throws {
        let (delegate, _) = try await working()
        try delegate.interrupt()
        channel.feed(#"{"id":5,"error":{"code":-32600,"message":"expected active turn id \#(F.turnID) but found t2"}}"#)
        await eventually { channel.written.count == 7 }
        XCTAssertEqual(channel.written.last,
                       #"{"id":6,"method":"turn/interrupt","params":{"threadId":"\#(F.threadID)","turnId":"t2"}}"#)
    }

    /// A Codex subagent's thread neither ends TapQ's turn nor becomes its reply.
    func testAnotherThreadNeitherEndsNorAnswersTapQsTurn() async throws {
        let (_, recorder) = try await working()
        let other = { (line: String) in line.replacingOccurrences(of: F.threadID, with: "subagent-thread") }
        channel.feed(other(F.turnStarted("sub-turn")))
        channel.feed(other(F.agentMessageCompleted("the subagent's words", id: "sub-msg", phase: #""commentary""#)))
        channel.feed(other(F.commandApproval(id: 70)))
        channel.feed(other(F.resolved("70")))
        channel.feed(other(F.turnCompleted("completed", turn: "sub-turn")))
        channel.feed(F.agentMessageCompleted("the answer"))
        channel.feed(F.turnCompleted("completed"))

        await eventually { recorder.events.count == 4 }
        guard case .permission(let request) = recorder.events[1] else { return XCTFail("no permission") }
        XCTAssertEqual(request.id, "70", "another thread's request is still asked")
        XCTAssertEqual(recorder.events[2], .withdrawn(requestID: "70"), "and its resolution still withdraws it")
        XCTAssertEqual(recorder.events[3], .finished(text: "the answer"), "the subagent's words are not TapQ's agent's")
    }

    /// A "but found" that names the turn TapQ just tried is not retried: no loop.
    func testAnInterruptMismatchNamingTheSameTurnIsNotRetried() async throws {
        let (delegate, recorder) = try await working()
        try delegate.interrupt()
        channel.feed(#"{"id":5,"error":{"code":-32600,"message":"expected active turn id \#(F.turnID) but found \#(F.turnID)"}}"#)
        // A notification that emits, so the error has certainly been handled.
        channel.feed(F.commandStarted)
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(channel.written.count, 6, "no second turn/interrupt")
    }

    func testAnUppercaseSteerRaceStillStartsTheTurn() async throws {
        let (delegate, _) = try await working()
        try delegate.send("and the docs")
        channel.feed(F.turnCompleted("completed"))
        channel.feed(#"{"id":5,"error":{"code":-32600,"message":"No active turn to steer."}}"#)

        await eventually { channel.written.count == 7 }
        XCTAssertEqual(channel.written.last, Self.turnStart(id: 6, "and the docs"))
    }

    /// `activeTurnNotSteerable` is a refusal, never the race, whatever the message says.
    func testATypedNotSteerableRefusalIsNeverTheRace() async throws {
        let (delegate, recorder) = try await working()
        try delegate.send("and the docs")
        channel.feed(#"{"id":5,"error":{"code":-32600,"message":"no active turn to steer","data":{"codexErrorInfo":{"activeTurnNotSteerable":{"turnKind":"review"}}}}}"#)

        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .notice(
            "Codex couldn't take that while it works: no active turn to steer. Say it again when it's done."))
        XCTAssertEqual(channel.written.count, 6, "no turn/start")
    }

    func testInterruptStopsTheTurn() async throws {
        let (delegate, recorder) = try await working()
        try delegate.interrupt()
        XCTAssertEqual(channel.written.last,
                       #"{"id":5,"method":"turn/interrupt","params":{"threadId":"\#(F.threadID)","turnId":"\#(F.turnID)"}}"#)

        channel.feed(#"{"id":5,"result":{}}"#)
        channel.feed(F.turnCompleted("interrupted"))
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .stopped)
    }

    func testInterruptCrossingTheTurnsEndIsNotAViolation() async throws {
        let (delegate, recorder) = try await working()
        try delegate.interrupt()
        channel.feed(F.turnCompleted("completed"))
        channel.feed(#"{"id":5,"error":{"code":-32600,"message":"no active turn to interrupt"}}"#)
        channel.feed(F.commandStarted)

        await eventually { recorder.events.count == 3 }
        XCTAssertEqual(recorder.events, [.progress("running npm test", step: "item-cmd"), .finished(text: ""), .progress("running npm test", step: "item-cmd")])
    }

    func testInterruptOfAStartingTurnWaitsForItsID() async throws {
        let delegate = makeDelegate()
        try await start(delegate)
        try delegate.send("run the tests")
        try delegate.interrupt()
        XCTAssertEqual(channel.written.count, 5)

        channel.feed(F.turnStarted())
        await eventually { channel.written.count == 6 }
        XCTAssertEqual(channel.written.last,
                       #"{"id":5,"method":"turn/interrupt","params":{"threadId":"\#(F.threadID)","turnId":"\#(F.turnID)"}}"#)
    }

    func testCompletedTurnFinishesWithItsLastAgentMessage() async throws {
        let (_, recorder) = try await working()
        channel.feed(F.agentMessageCompleted("Running the tests now.", id: "m1", phase: #""commentary""#))
        channel.feed(F.agentMessageCompleted("All 12 tests pass.", id: "m2"))
        channel.feed(F.turnCompleted("completed"))

        await eventually { recorder.events.count == 3 }
        XCTAssertEqual(Array(recorder.events.suffix(2)),
                       [.said("Running the tests now."), .finished(text: "All 12 tests pass.")],
                       "commentary is its words along the way, for status (2026-10-15); the final answer is the reply")
    }

    func testAMessageWithoutAPhaseIsBothWordsAlongTheWayAndTheReply() async throws {
        let (_, recorder) = try await working()
        channel.feed(F.agentMessageCompleted("Running the tests now.", id: "m1", phase: "null"))
        channel.feed(F.agentMessageCompleted("All 12 tests pass.", id: "m2", phase: "null"))
        channel.feed(F.turnCompleted("completed"))

        await eventually { recorder.events.count == 4 }
        XCTAssertEqual(Array(recorder.events.suffix(3)),
                       [.said("Running the tests now."), .said("All 12 tests pass."), .finished(text: "All 12 tests pass.")])
    }

    func testFailedTurnReportsItsErrorMessage() async throws {
        let (_, recorder) = try await working()
        channel.feed(F.turnCompleted("failed", error: F.usageLimitError))

        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .failed(reason: "You've hit your usage limit."))
    }

    func testOpenRequestsAreWithdrawnBeforeTheTerminalEvent() async throws {
        let (_, recorder) = try await working()
        channel.feed(F.commandApproval(id: 30))
        channel.feed(F.permissionsApproval(id: 31))
        channel.feed(F.turnCompleted("interrupted"))

        await eventually { recorder.events.count == 6 }
        XCTAssertEqual(Array(recorder.events.suffix(3)),
                       [.withdrawn(requestID: "30"), .withdrawn(requestID: "31"), .stopped])
    }

    // MARK: - Approvals

    func testCommandApprovalMapsToAPermissionWithEveryDecision() async throws {
        let (delegate, recorder) = try await working()
        let decisions: [(PermissionDecision, String)] = [
            (.allow(always: false), "accept"), (.allow(always: true), "acceptForSession"), (.deny(feedback: nil), "decline"),
        ]
        for (index, (decision, wire)) in decisions.enumerated() {
            channel.feed(F.commandApproval(id: 30 + index))
            await eventually { recorder.events.count == 2 + index }
            guard case .permission(let request) = recorder.events.last else { return XCTFail("no permission") }
            XCTAssertEqual(request.id, "\(30 + index)")
            XCTAssertEqual(request.tool, "commandExecution")
            XCTAssertEqual(request.command, "npm install")
            XCTAssertEqual(request.reason, "needs network to install")
            XCTAssertEqual(request.alwaysAllow?.payloadJSON, #""acceptForSession""#)
            XCTAssertTrue(request.inputJSON.contains(#""command":"npm install""#))

            try delegate.resolve(permission: request.id, decision)
            XCTAssertEqual(channel.written.last, #"{"id":\#(30 + index),"result":{"decision":"\#(wire)"}}"#)
        }
    }

    func testANetworkApprovalNamesTheHostAndCannotBeAllowedForTheSession() async throws {
        let (delegate, recorder) = try await working()
        channel.feed(F.networkApproval)
        await eventually { recorder.events.count == 2 }
        guard case .permission(let request) = recorder.events.last else { return XCTFail("no permission") }
        XCTAssertEqual(request.id, "net-1")
        XCTAssertNil(request.command)
        XCTAssertEqual(request.title, "network access to registry.npmjs.org")
        XCTAssertNil(request.alwaysAllow)

        try delegate.resolve(permission: "net-1", .allow(always: true))
        XCTAssertEqual(channel.written.last, #"{"id":"net-1","result":{"decision":"accept"}}"#)
    }

    /// Live 2026-10-12 (0.161.0): a command offered no `acceptForSession`, only an execpolicy
    /// amendment, which writes a rule to `~/.codex/rules/default.rules` for every later Codex
    /// session. A spoken "don't ask again" never writes Codex's rules (maintainer ruling
    /// 2026-10-12): the command is accepted once.
    func testDontAskAgainNeverWritesCodexsRules() async throws {
        let (delegate, recorder) = try await working()
        let rule = #"["/bin/bash","-lc","npm install"]"#
        let offered = #""availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":\#(rule)}},"cancel"],"proposedExecpolicyAmendment":\#(rule)"#
        channel.feed(F.commandApproval(id: 34).replacingOccurrences(of: #""cwd":"/work/project""#,
                                                                    with: #""cwd":"/work/project","# + offered))
        await eventually { recorder.events.count == 2 }
        guard case .permission(let request) = recorder.events.last else { return XCTFail("no permission") }
        XCTAssertTrue(request.inputJSON.contains("acceptWithExecpolicyAmendment"))
        XCTAssertNil(request.alwaysAllow)

        try delegate.resolve(permission: "34", .allow(always: true))
        XCTAssertEqual(channel.written.last, #"{"id":34,"result":{"decision":"accept"}}"#)
        XCTAssertFalse(channel.written.contains { $0.lowercased().contains("execpolicy") })
    }

    /// Live 2026-10-11, Codex sent every command as `/bin/bash -lc '<command>'`: the request
    /// and the status line read the command inside it, and the record keeps the wrapper.
    func testTheBashWrapperIsReadAsTheCommandInsideIt() async throws {
        let (_, recorder) = try await working()
        let wrapped = #""command":"/bin/bash -lc 'sh check.sh 40'""#
        channel.feed(F.commandStarted.replacingOccurrences(of: #""command":"npm test""#, with: wrapped))
        channel.feed(F.commandApproval(id: 33).replacingOccurrences(of: #""command":"npm install""#,
                                                                    with: wrapped))
        await eventually { recorder.events.count == 3 }
        XCTAssertEqual(recorder.events[1], .progress("running sh check.sh 40", step: "item-cmd"))
        guard case .permission(let request) = recorder.events.last else { return XCTFail("no permission") }
        XCTAssertEqual(request.command, "sh check.sh 40")
        XCTAssertTrue(request.inputJSON.contains("/bin/bash -lc 'sh check.sh 40'"))
    }

    /// Any other shape is read whole: another shell or flag, a quote inside single quotes
    /// (Codex's `'\''`), anything double quotes would unescape or expand, nothing inside, or
    /// more after the closing quote.
    func testOnlyTheExactBashWrapperIsUnwrapped() async throws {
        XCTAssertEqual(CodexMapper.spokenCommand("/bin/bash -lc 'curl --head https://example.com'"),
                       "curl --head https://example.com")
        // Live 2026-10-12: a command with a `'` comes double-quoted.
        XCTAssertEqual(CodexMapper.spokenCommand(#"/bin/bash -lc "rm -rf ./tests/__pycache__ && echo 'No caches remain.'""#),
                       "rm -rf ./tests/__pycache__ && echo 'No caches remain.'")
        XCTAssertEqual(CodexMapper.spokenCommand(#"/bin/bash -lc "curl x""#), "curl x")
        for whole in ["/bin/bash -c 'curl x'", "/bin/zsh -lc 'curl x'", #"/bin/bash -c "curl x""#,
                      #"/bin/bash -lc 'echo '\''hi'\'''"#, "/bin/bash -lc ''", "/bin/bash -lc '  '",
                      #"/bin/bash -lc """#, #"/bin/bash -lc "  ""#,
                      #"/bin/bash -lc "echo \"hi\"""#, #"/bin/bash -lc "echo $HOME""#,
                      #"/bin/bash -lc "echo `date`""#, #"/bin/bash -lc "a\\b""#,
                      #"/bin/bash -lc "a" && rm "b""#, #"/bin/bash -lc 'curl x""#,
                      "/bin/bash -lc 'a' && rm 'b'", "/bin/bash -lc 'curl x' && rm y", "npm install"] {
            XCTAssertEqual(CodexMapper.spokenCommand(whole), whole, whole)
        }
    }

    func testFileChangeApprovalTakesItsPathsFromTheStartedItem() async throws {
        let (delegate, recorder) = try await working()
        channel.feed(F.fileChangeStarted)
        channel.feed(F.fileChangeApproval(id: 32))
        await eventually { recorder.events.count == 3 }
        XCTAssertEqual(recorder.events[1], .progress("editing Sources/App.swift, README.md", step: "item-patch"))
        guard case .permission(let request) = recorder.events.last else { return XCTFail("no permission") }
        XCTAssertEqual(request.tool, "fileChange")
        XCTAssertEqual(request.paths, ["Sources/App.swift", "README.md"])
        XCTAssertTrue(request.inputJSON.contains(#""diff":"+hello\n""#))
        XCTAssertNotNil(request.alwaysAllow)

        try delegate.resolve(permission: "32", .allow(always: true))
        XCTAssertEqual(channel.written.last, #"{"id":32,"result":{"decision":"acceptForSession"}}"#)
    }

    func testACommandCodexParsedIsNamedAsCodexShowsIt() async throws {
        let (_, recorder) = try await working()
        channel.feed(F.commandStarted(actions: #"[{"type":"read","command":"cat README.md","name":"README.md","path":"/work/project/README.md"},{"type":"read","command":"cat a.swift","name":"a.swift","path":"/work/project/a.swift"}]"#))
        channel.feed(F.commandStarted(actions: #"[{"type":"listFiles","command":"ls Sources","path":"Sources"},{"type":"search","command":"rg -n TODO Sources","query":"TODO","path":"Sources"}]"#))
        channel.feed(F.commandStarted(actions: #"[{"type":"search","command":"rg TODO","query":"TODO","path":null},{"type":"listFiles","command":"ls","path":null}]"#))
        channel.feed(F.commandStarted(actions: #"[{"type":"listFiles","command":"ls","path":null},{"type":"listFiles","command":"ls -la","path":null},{"type":"search","command":"rg TODO","query":"TODO","path":null}]"#))
        channel.feed(F.commandStarted(actions: #"[{"type":"read","command":"cat a.swift","name":"a.swift","path":"a.swift"},{"type":"unknown","command":"npm test"}]"#))

        await eventually { recorder.events.count == 6 }
        XCTAssertEqual(Array(recorder.events.suffix(5)), [
            .progress("reading README.md, a.swift", step: "item-cmd"),
            .progress("listing Sources, then searching for TODO in Sources", step: "item-cmd"),
            .progress("searching for TODO, then listing files", step: "item-cmd"),
            .progress("listing files, then searching for TODO", step: "item-cmd"),
            .progress("running npm test", step: "item-cmd"),
        ], "any action Codex could not parse leaves the command whole, as its own screen does")
    }

    /// A step ends with its `item/completed`, as Codex's screen turns "Running" into "Ran"
    /// (2026-10-15): its status, a non-zero exit failing a command that completed. Only the
    /// items that started a step end one.
    func testACompletedItemEndsItsStep() async throws {
        let (_, recorder) = try await working()
        channel.feed(F.commandStarted)
        channel.feed(F.commandCompleted(status: "completed", exitCode: "0"))
        channel.feed(F.commandCompleted(status: "completed", exitCode: "1"))
        channel.feed(F.commandCompleted(status: "failed", exitCode: "null"))
        channel.feed(F.commandCompleted(status: "declined", exitCode: "null"))
        channel.feed(F.commandCompleted(status: "inProgress", exitCode: "null"))
        channel.feed(F.fileChangeCompleted(status: "completed"))
        channel.feed(F.agentMessageCompleted("Done.", phase: #""commentary""#))

        await eventually { recorder.events.count == 8 }
        XCTAssertEqual(Array(recorder.events.suffix(7)), [
            .progress("running npm test", step: "item-cmd"),
            .stepEnded(step: "item-cmd", .done),
            .stepEnded(step: "item-cmd", .failed),
            .stepEnded(step: "item-cmd", .failed),
            .stepEnded(step: "item-cmd", .declined),
            .stepEnded(step: "item-patch", .done),
            .said("Done."),
        ])
    }

    /// An approval names the item it asks about: that step waits on the user.
    func testAnApprovalNamesItsStep() async throws {
        let (_, recorder) = try await working()
        channel.feed(F.fileChangeStarted)
        channel.feed(F.fileChangeApproval(id: 32))
        await eventually { recorder.events.count == 3 }
        guard case .permission(let request) = recorder.events[2] else { return XCTFail("no permission") }
        XCTAssertEqual(request.step, "item-patch")
    }

    /// Another thread's items start no step, so they end none.
    func testAnotherThreadsItemsEndNoStep() async throws {
        let (_, recorder) = try await working()
        let other = { (line: String) in line.replacingOccurrences(of: F.threadID, with: "subagent-thread") }
        channel.feed(other(F.commandStarted))
        channel.feed(other(F.commandCompleted(status: "completed", exitCode: "0")))
        channel.feed(F.agentMessageCompleted("the answer"))
        channel.feed(F.turnCompleted("completed"))
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(Array(recorder.events.suffix(1)), [.finished(text: "the answer")])
    }

    /// Nothing promises the item comes first: without it the approval is asked from what it
    /// says itself, its grant root when it has one.
    func testFileChangeApprovalForAnUnseenItemIsStillAsked() async throws {
        let (delegate, recorder) = try await working()
        channel.feed(F.fileChangeApproval(id: 32, item: "never-started"))
        channel.feed(F.fileChangeApproval(id: 33, item: "never-started")
            .replacingOccurrences(of: #""reason":null"#, with: #""reason":null,"grantRoot":"/work/project/gen""#))
        await eventually { recorder.events.count == 3 }
        guard case .permission(let bare) = recorder.events[1],
              case .permission(let rooted) = recorder.events[2] else { return XCTFail("no permissions") }
        XCTAssertEqual(bare.paths, [])
        XCTAssertEqual(bare.inputJSON, "{}")
        XCTAssertEqual(bare.title, "changes to files it has not named")
        XCTAssertEqual(rooted.title, "write access under /work/project/gen")

        try delegate.resolve(permission: "32", .allow(always: false))
        XCTAssertEqual(channel.written.last, #"{"id":32,"result":{"decision":"accept"}}"#)
    }

    func testPermissionsApprovalEchoesTheProfileOrGrantsNothing() async throws {
        let (delegate, recorder) = try await working()
        let decisions: [(PermissionDecision, String)] = [
            (.allow(always: false), #"{"permissions":{"network":{"enabled":true}},"scope":"turn"}"#),
            (.allow(always: true), #"{"permissions":{"network":{"enabled":true}},"scope":"session"}"#),
            (.deny(feedback: nil), #"{"permissions":{},"scope":"turn"}"#),
        ]
        for (index, (decision, reply)) in decisions.enumerated() {
            channel.feed(F.permissionsApproval(id: 33 + index))
            await eventually { recorder.events.count == 2 + index }
            guard case .permission(let request) = recorder.events.last else { return XCTFail("no permission") }
            XCTAssertEqual(request.tool, "permissions")
            XCTAssertEqual(request.title, "network access")
            XCTAssertEqual(request.reason, "fetch the schema")
            XCTAssertNotNil(request.alwaysAllow)

            try delegate.resolve(permission: request.id, decision)
            XCTAssertEqual(channel.written.last, #"{"id":\#(33 + index),"result":\#(reply)}"#)
        }
    }

    func testDeclineWithFeedbackSteersTheReason() async throws {
        let (delegate, recorder) = try await working()
        channel.feed(F.commandApproval(id: 30))
        await eventually { recorder.events.count == 2 }

        try delegate.resolve(permission: "30", .deny(feedback: "use pnpm"))
        XCTAssertEqual(Array(channel.written.suffix(2)), [
            #"{"id":30,"result":{"decision":"decline"}}"#,
            Self.steer(id: 5, "The user declined: use pnpm"),
        ])
        XCTAssertThrowsError(try delegate.resolve(permission: "30", .allow(always: false))) {
            XCTAssertEqual($0 as? CodexDelegateError, .unknownRequest("30"))
        }
    }

    // MARK: - Questions

    func testRequestUserInputAsksEveryQuestionAndAnswersByID() async throws {
        let (delegate, recorder) = try await working()
        channel.feed(F.userInput)
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .question(QuestionRequest(id: "40", questions: [
            Question(key: "db", header: "Database", text: "Which database?",
                     options: [QuestionOption(label: "Postgres", description: "server"),
                               QuestionOption(label: "SQLite", description: "file")],
                     multiSelect: false, allowsFreeText: true),
            Question(key: "name", header: "Name", text: "What should the table be called?",
                     options: [], multiSelect: false, allowsFreeText: false),
        ])))

        XCTAssertThrowsError(try delegate.resolve(question: "40", answers: [["SQLite"]]))
        XCTAssertThrowsError(try delegate.resolve(permission: "40", .allow(always: false)))
        try delegate.resolve(question: "40", answers: [["SQLite"], ["users"]])
        XCTAssertEqual(channel.written.last,
                       #"{"id":40,"result":{"answers":{"db":{"answers":["SQLite"]},"name":{"answers":["users"]}}}}"#)
    }

    /// Never read aloud; the user is told to type it in Codex (§7.2).
    func testSecretQuestionsAreAnsweredEmptyAndNeverAsked() async throws {
        let (delegate, recorder) = try await working()
        channel.feed(F.allSecretInput)
        await eventually { channel.written.count == 6 }
        XCTAssertEqual(channel.written.last, #"{"id":42,"result":{"answers":{"token":{"answers":[]}}}}"#)
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .notice("Codex asked for a secret; type it in Codex."))

        channel.feed(F.mixedSecretInput)
        await eventually { recorder.events.count == 4 }
        guard case .question(let request) = recorder.events[2] else { return XCTFail("no question") }
        XCTAssertEqual(request.questions.map(\.key), ["env"])
        XCTAssertEqual(recorder.events[3], .notice("Codex asked for a secret; type it in Codex."))

        try delegate.resolve(question: "41", answers: [["staging"]])
        XCTAssertEqual(channel.written.last,
                       #"{"id":41,"result":{"answers":{"env":{"answers":["staging"]},"token":{"answers":[]}}}}"#)
    }

    // MARK: - Other server messages

    func testServerRequestResolvedWithdrawsOnlyUnansweredRequests() async throws {
        let (delegate, recorder) = try await working()
        channel.feed(F.commandApproval(id: 30))
        channel.feed(F.networkApproval)
        await eventually { recorder.events.count == 3 }
        try delegate.resolve(permission: "30", .allow(always: false))

        channel.feed(F.resolved("30"))
        channel.feed(F.resolved(#""net-1""#))
        await eventually { recorder.events.count == 4 }
        XCTAssertEqual(recorder.events.last, .withdrawn(requestID: "net-1"))
        let written = channel.written.count
        try delegate.resolve(permission: "net-1", .allow(always: false))
        XCTAssertEqual(channel.written.count, written)
    }

    /// The kernel decided in the moment Codex withdrew the request: nothing is written,
    /// nothing throws (V2 P1-1). An id Codex never sent still throws.
    func testADecisionCrossingTheTurnsEndIsDropped() async throws {
        let (delegate, recorder) = try await working()
        channel.feed(F.commandApproval(id: 30))
        channel.feed(F.userInput)
        channel.feed(F.turnCompleted("interrupted"))
        await eventually { recorder.events.count == 6 }
        let written = channel.written.count

        try delegate.resolve(permission: "30", .deny(feedback: "use pnpm"))
        try delegate.resolve(question: "40", answers: [["SQLite"], ["users"]])
        XCTAssertEqual(channel.written.count, written)
        XCTAssertThrowsError(try delegate.resolve(permission: "99", .allow(always: false))) {
            XCTAssertEqual($0 as? CodexDelegateError, .unknownRequest("99"))
        }
    }

    /// Only the last 64 withdrawals are remembered.
    func testTheWithdrawnMemoryIsBounded() async throws {
        let (delegate, recorder) = try await working()
        for id in 100..<165 { channel.feed(F.commandApproval(id: id)) }
        channel.feed(F.turnCompleted("interrupted"))
        await eventually { recorder.events.last == .stopped }

        try delegate.resolve(permission: "101", .allow(always: false))
        XCTAssertThrowsError(try delegate.resolve(permission: "100", .allow(always: false))) {
            XCTAssertEqual($0 as? CodexDelegateError, .unknownRequest("100"))
        }
    }

    func testElicitationIsDeclinedOutLoud() async throws {
        let (_, recorder) = try await working()
        channel.feed(F.elicitation)
        await eventually { channel.written.count == 6 }
        XCTAssertEqual(channel.written.last, #"{"id":50,"result":{"action":"decline","content":null,"_meta":null}}"#)
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .notice("Codex's github server asked for input; I declined."))
    }

    func testUnknownRequestGetsMethodNotFound() async throws {
        _ = try await working()
        channel.feed(F.dynamicToolCall)
        await eventually { channel.written.count == 6 }
        XCTAssertEqual(channel.written.last,
                       #"{"id":60,"error":{"code":-32601,"message":"TapQ does not handle item/tool/call"}}"#)
    }

    func testUnknownNotificationsAndChatterAreIgnored() async throws {
        let (_, recorder) = try await working()
        channel.feed(#"{"method":"thread/goal/updated","params":{"threadId":"t"}}"#)
        channel.feed(#"{"method":"error","params":{"error":{"message":"retrying","codexErrorInfo":"serverOverloaded","additionalDetails":null,"misalignment":null},"willRetry":true,"threadId":"t","turnId":"u"}}"#)
        channel.feed("WARN codex starting")
        channel.feed(F.commandStarted)

        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events, [.progress("running npm test", step: "item-cmd"), .progress("running npm test", step: "item-cmd")])
    }

    func testAnUndecodableLineIsAViolation() async throws {
        let (_, recorder) = try await working()
        channel.feed(#"{"id":1,"result""#)
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .violation("Codex sent a line that is not JSON-RPC (16 characters)"))
    }

    // MARK: - Process

    func testExitReportsTheStderrTail() async throws {
        let (_, recorder) = try await working()
        channel.feed(.stderr("thread panicked"))
        channel.feed(.exited(101))
        await eventually { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events.last, .exited(code: 101, stderrTail: ["thread panicked"]))
    }

    /// D13: 5 s after stdin closes, SIGTERM; 2 s later, SIGKILL. The exit says nothing.
    func testStopTerminatesWithTheD13TimingsAndReportsNoExit() async throws {
        let (delegate, recorder) = try await working()
        await delegate.stop()
        XCTAssertTrue(channel.inputClosed)
        XCTAssertEqual(channel.terminated?.grace, .seconds(5))
        XCTAssertEqual(channel.terminated?.killAfter, .seconds(2))
        XCTAssertEqual(recorder.events, [.progress("running npm test", step: "item-cmd")])
        XCTAssertThrowsError(try delegate.send("hi"))
    }

    // MARK: -

    private func assertStartThrows(_ delegate: CodexDelegate, _ expected: CodexDelegateError,
                                   session: DelegateSession = .fresh,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await start(delegate, session)
            XCTFail("start returned", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodexDelegateError, expected, file: file, line: line)
        }
    }
}
