import XCTest
import TapQContracts
@testable import TapQContextBaseline

final class SessionContextStoreTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() -> SessionContextStore {
        let tick = TickingClock(origin: epoch)
        return SessionContextStore(clock: { tick.next() })
    }

    // MARK: - Bounds

    func testEventRingKeepsTheNewestEventsPerSession() {
        var store = makeStore()
        for index in 1...(SessionContextStore.eventCapacity + 4) {
            store.record(
                session: "s1",
                kind: .approval,
                agentDisplayName: "Claude Code",
                summary: "step \(index)",
                outcome: .allowed
            )
        }

        let events = store.events(session: "s1")
        XCTAssertEqual(events.count, SessionContextStore.eventCapacity)
        XCTAssertEqual(events.first?.summary, "step 5")
        XCTAssertEqual(events.last?.summary, "step 20")
    }

    func testSessionsAreIsolated() {
        var store = makeStore()
        store.record(
            session: "s1", kind: .approval, agentDisplayName: "Claude Code",
            summary: "run npm test", outcome: .allowed
        )
        store.record(
            session: "s2", kind: .approval, agentDisplayName: "Codex",
            summary: "delete the cache", outcome: .denied
        )

        XCTAssertEqual(store.events(session: "s1").map(\.summary), ["run npm test"])
        XCTAssertEqual(store.events(session: "s2").map(\.summary), ["delete the cache"])
        XCTAssertTrue(store.events(session: "s3").isEmpty)
    }

    func testSessionCapacityEvictsTheFirstSeenSessionWhole() {
        var store = makeStore()
        for index in 1...(SessionContextStore.sessionCapacity + 2) {
            store.record(
                session: "s\(index)", kind: .approval, agentDisplayName: "Claude Code",
                summary: "step \(index)", outcome: .allowed
            )
        }

        XCTAssertEqual(store.trackedSessions.count, SessionContextStore.sessionCapacity)
        XCTAssertTrue(store.events(session: "s1").isEmpty)
        XCTAssertTrue(store.events(session: "s2").isEmpty)
        XCTAssertEqual(store.events(session: "s3").map(\.summary), ["step 3"])
        XCTAssertEqual(store.trackedSessions.first, "s3")
    }

    func testRecordingIntoATrackedSessionDoesNotReorderEviction() {
        var store = makeStore()
        for index in 1...SessionContextStore.sessionCapacity {
            store.record(
                session: "s\(index)", kind: .approval, agentDisplayName: "Claude Code",
                summary: "step \(index)", outcome: .allowed
            )
        }
        store.record(
            session: "s1", kind: .approval, agentDisplayName: "Claude Code",
            summary: "later step", outcome: .allowed
        )
        store.record(
            session: "s9", kind: .approval, agentDisplayName: "Claude Code",
            summary: "step 9", outcome: .allowed
        )

        XCTAssertTrue(store.events(session: "s1").isEmpty)
        XCTAssertEqual(store.trackedSessions.first, "s2")
    }

    func testRecentReturnsNewestFirstAndHonoursTheLimit() {
        var store = makeStore()
        for index in 1...4 {
            store.record(
                session: "s1", kind: .approval, agentDisplayName: "Claude Code",
                summary: "step \(index)", outcome: .allowed
            )
        }

        XCTAssertEqual(
            store.recent(session: "s1", limit: 2).map(\.summary),
            ["step 4", "step 3"]
        )
        XCTAssertTrue(store.recent(session: "s1", limit: 0).isEmpty)
        XCTAssertEqual(store.recent(session: "s1", limit: 99).count, 4)
    }

    // MARK: - Field completeness

    func testApprovalRecordsEverySpeechSafeField() throws {
        var store = makeStore()
        store.record(approval: request(decisionSummary: "run npm test"), decision: .allow)

        let event = try XCTUnwrap(store.events(session: "s1").first)
        XCTAssertEqual(event.kind, .approval)
        XCTAssertEqual(event.agentDisplayName, "Claude Code")
        XCTAssertEqual(event.summary, "run npm test")
        XCTAssertEqual(event.detail, "Runs the unit test suite.")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.outcome, .allowed)
        XCTAssertEqual(event.timestamp, epoch)
    }

    func testDecisionsMapToOutcomes() {
        var store = makeStore()
        store.record(approval: request(), decision: .allow)
        store.record(approval: request(), decision: .deny)
        store.record(approval: request(), decision: .ask)

        XCTAssertEqual(
            store.events(session: "s1").map(\.outcome),
            [.allowed, .denied, .deferred]
        )
    }

    func testSelectionRecordsChosenLabels() {
        var store = makeStore()
        store.record(
            selection: selectionRequest(),
            result: SelectionResult(choices: [
                SelectionResult.Choice(index: 0, label: "Rebase"),
                SelectionResult.Choice(index: 1, label: "Merge"),
            ])
        )

        let event = store.events(session: "s1").first
        XCTAssertEqual(event?.kind, .selection)
        XCTAssertEqual(event?.summary, "Which merge strategy?")
        XCTAssertEqual(event?.outcome, .chose(["Rebase", "Merge"]))
    }

    func testSelectionFreeTextAndTimeoutMapToAnsweredAndDeferred() {
        var store = makeStore()
        store.record(
            selection: selectionRequest(),
            result: SelectionResult(choices: [], freeText: "use the second one")
        )
        store.record(selection: selectionRequest(), result: .noSelection)

        XCTAssertEqual(
            store.events(session: "s1").map(\.outcome),
            [.answered("use the second one"), .deferred]
        )
    }

    func testStopAnswerRecordsTheSpokenAnswer() {
        var store = makeStore()
        store.recordStopAnswer(
            session: "s1",
            agent: .claudeCode,
            question: "Should I open a pull request?",
            detail: "The branch is ready to push.",
            answer: "yes"
        )

        let event = store.events(session: "s1").first
        XCTAssertEqual(event?.kind, .stopAnswer)
        XCTAssertEqual(event?.summary, "Should I open a pull request?")
        XCTAssertEqual(event?.detail, "The branch is ready to push.")
        XCTAssertEqual(event?.outcome, .answered("yes"))
    }

    func testDeliveredInstructionIsRecordedAsItsOwnKind() {
        var store = makeStore()
        store.recordInstruction(
            session: "s1",
            agent: .claudeCode,
            text: "run the tests again"
        )

        let event = store.events(session: "s1").first
        XCTAssertEqual(event?.kind, .instruction)
        XCTAssertEqual(event?.agentDisplayName, "Claude Code")
        XCTAssertEqual(event?.summary, "run the tests again")
        XCTAssertEqual(event?.outcome, .instructed)
    }

    func testNotificationWithoutASummaryFallsBackToItsKind() {
        var store = makeStore()
        store.record(notification: AgentNotification(
            sessionID: "s1", agent: .claudeCode, kind: .waitingForInput
        ))
        store.record(notification: AgentNotification(
            sessionID: "s1", agent: .claudeCode, kind: .finished, summary: "  "
        ))
        store.record(notification: AgentNotification(
            sessionID: "s1", agent: .claudeCode, kind: .finished, summary: "tests passed"
        ))

        XCTAssertEqual(
            store.events(session: "s1").map(\.summary),
            ["waiting for input", "finished", "tests passed"]
        )
        XCTAssertEqual(store.events(session: "s1").map(\.outcome), [.noted, .noted, .noted])
    }

    // MARK: - Caps and clock

    func testTextFieldsAreCappedAndWhitespaceNormalized() {
        var store = makeStore()
        store.record(
            session: "s1",
            kind: .approval,
            agentDisplayName: "Claude\n Code",
            summary: String(repeating: "word ", count: 60),
            detail: String(repeating: "sentence text ", count: 60),
            toolName: "Bash",
            outcome: .answered(String(repeating: "a", count: 400))
        )

        let event = store.events(session: "s1").first
        XCTAssertEqual(event?.agentDisplayName, "Claude Code")
        XCTAssertLessThanOrEqual(
            event?.summary.count ?? .max, SessionContextEvent.summaryCharacterLimit
        )
        XCTAssertLessThanOrEqual(
            event?.detail.count ?? .max, SessionContextEvent.detailCharacterLimit
        )
        if case let .answered(text)? = event?.outcome {
            XCTAssertLessThanOrEqual(text.count, SessionContextEvent.summaryCharacterLimit)
        } else {
            XCTFail("expected an answered outcome")
        }
    }

    func testEmptyOutcomeTextDegradesToDeferred() {
        var store = makeStore()
        store.record(
            session: "s1", kind: .selection, agentDisplayName: "Codex",
            summary: "Which one?", outcome: .chose(["  ", ""])
        )
        store.record(
            session: "s1", kind: .stopAnswer, agentDisplayName: "Codex",
            summary: "Ready?", outcome: .answered("   ")
        )

        XCTAssertEqual(store.events(session: "s1").map(\.outcome), [.deferred, .deferred])
    }

    func testEventsAreStampedByTheInjectedClock() {
        var store = makeStore()
        store.record(approval: request(), decision: .allow)
        store.record(approval: request(), decision: .deny)

        XCTAssertEqual(
            store.events(session: "s1").map(\.timestamp),
            [epoch, epoch.addingTimeInterval(1)]
        )
    }

    // MARK: - Redaction

    func testApprovalContextNeverReachesARecordedEvent() throws {
        var store = makeStore()
        store.record(approval: request(), decision: .allow)

        let event = try XCTUnwrap(store.events(session: "s1").first)
        let rendered = [
            event.summary, event.detail, event.toolName, event.agentDisplayName,
            SessionRecall.whatChanged(store.recent(session: "s1", limit: 3)),
            SessionRecall.digest(
                events: store.recent(session: "s1", limit: 3),
                currentSummary: event.summary,
                currentDetail: event.detail
            ),
        ].joined(separator: " ")

        XCTAssertFalse(rendered.contains("/"))
        XCTAssertFalse(rendered.contains("Users"))
        XCTAssertFalse(rendered.contains("secret-project"))
        XCTAssertFalse(rendered.contains("rm -rf"))
        XCTAssertFalse(rendered.lowercased().contains("bypasspermissions"))
    }

    // MARK: - Helpers

    private func request(decisionSummary: String = "run npm test") -> ApprovalRequest {
        ApprovalRequest(
            id: "r1",
            sessionID: "s1",
            agent: .claudeCode,
            toolName: "Bash",
            summary: decisionSummary,
            detail: "Runs the unit test suite.",
            toolInput: ["command": .string("rm -rf /Users/someone/secret-project")],
            cwd: "/Users/someone/secret-project",
            permissionMode: "bypassPermissions"
        )
    }

    private func selectionRequest() -> SelectionRequest {
        SelectionRequest(
            id: "sel1",
            sessionID: "s1",
            agent: .claudeCode,
            question: "Which merge strategy?",
            options: [
                SelectionOption(label: "Rebase", description: "Replay the commits."),
                SelectionOption(label: "Merge", description: "Keep both histories."),
            ]
        )
    }

    // MARK: - Background work and the finished boundary

    private func approval(
        session: String = "s1",
        command: String = "swift test",
        background: Bool?
    ) -> ApprovalRequest {
        var input: [String: JSONValue] = ["command": .string(command)]
        if let background { input["run_in_background"] = .bool(background) }
        return ApprovalRequest(
            id: "a-\(command)", sessionID: session,
            agent: AgentIdentity(id: "claude-code", displayName: "Claude Code"),
            toolName: "Bash", summary: "run \(command)", detail: "", toolInput: input
        )
    }

    private func finished(session: String = "s1") -> AgentNotification {
        AgentNotification(
            sessionID: session,
            agent: AgentIdentity(id: "claude-code", displayName: "Claude Code"),
            kind: .finished
        )
    }

    /// The 2026-09-01 hardware shape: the agent launches the suite in the background, its
    /// turn ends at once, and the "finished" that follows is the turn's, not the work's.
    func testAFinishedBoundaryAfterABackgroundLaunchLeftWorkRunning() {
        var store = makeStore()
        store.record(approval: approval(background: true), decision: .allow)

        XCTAssertEqual(store.record(notification: finished()), .leftWorkRunning)
        XCTAssertEqual(
            store.events(session: "s1").last?.summary,
            "finished, with work still running in the background"
        )
        // Settled once: the boundary after the agent is woken with the result is plain.
        XCTAssertEqual(store.record(notification: finished()), .complete)
        XCTAssertEqual(store.events(session: "s1").last?.summary, "finished")
    }

    func testAForegroundTurnFinishesComplete() {
        var store = makeStore()
        store.record(approval: approval(background: nil), decision: .allow)
        store.record(approval: approval(command: "ls", background: false), decision: .allow)

        XCTAssertEqual(store.record(notification: finished()), .complete)
        XCTAssertEqual(store.events(session: "s1").last?.summary, "finished")
    }

    /// A denied launch never ran. A launch deferred to the screen may have — the wearer
    /// approved it there — so it counts, exactly as an approved one does.
    func testADeniedLaunchDoesNotCountAndADeferredOneDoes() {
        var denied = makeStore()
        denied.record(approval: approval(background: true), decision: .deny)
        XCTAssertEqual(denied.record(notification: finished()), .complete)

        var deferred = makeStore()
        deferred.record(approval: approval(background: true), decision: .ask)
        XCTAssertEqual(deferred.record(notification: finished()), .leftWorkRunning)
    }

    func testTheLaunchFlagIsPerSessionAndOtherKindsReportNothing() {
        var store = makeStore()
        store.record(approval: approval(session: "s1", background: true), decision: .allow)

        XCTAssertNil(store.record(notification: AgentNotification(
            sessionID: "s1", kind: .waitingForInput
        )))
        XCTAssertEqual(store.record(notification: finished(session: "s2")), .complete)
        XCTAssertEqual(store.record(notification: finished(session: "s1")), .leftWorkRunning)
    }

    /// A finished boundary with the agent's own summary keeps that summary: the phrase is a
    /// fallback for an empty one, never a rewrite of what the agent said.
    func testTheAgentsOwnSummaryIsKeptOverThePhrase() {
        var store = makeStore()
        store.record(approval: approval(background: true), decision: .allow)

        let ending = store.record(notification: AgentNotification(
            sessionID: "s1",
            agent: AgentIdentity(id: "claude-code", displayName: "Claude Code"),
            kind: .finished, summary: "Tests are running in the background."
        ))

        XCTAssertEqual(ending, .leftWorkRunning)
        XCTAssertEqual(store.events(session: "s1").last?.summary,
                       "Tests are running in the background.")
    }
}

/// A clock that returns `origin`, `origin + 1s`, `origin + 2s`, … so a test can assert
/// exact timestamps and event ordering without touching the wall clock.
private final class TickingClock: @unchecked Sendable {
    private let origin: Date
    private let lock = NSLock()
    private var step = 0

    init(origin: Date) {
        self.origin = origin
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = origin.addingTimeInterval(TimeInterval(step))
        step += 1
        return value
    }
}
