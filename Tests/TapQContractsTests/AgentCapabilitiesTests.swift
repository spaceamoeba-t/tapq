import XCTest
import TapQContracts

/// The static capability table (RC6). These tests are the table's second copy: the
/// documented matrix in `docs/INTEGRATIONS.md` says the same four rows in prose, and a
/// change to one that is not made to the other is a documentation bug the reviewer can
/// see here.
final class AgentCapabilitiesTests: XCTestCase {
    /// The whole matrix, in one place, in the order the docs list it.
    func testTheShippedMatrix() {
        let expected: [(AgentIdentity, approvals: Bool, questions: Bool,
                        notifications: Bool, instructions: Bool)] = [
            (.claudeCode, true, true, true, true),
            (.codex, true, true, true, true),
            (.cursor, true, false, true, false),
            (.openCode, true, false, true, false),
        ]
        XCTAssertEqual(
            AgentCapabilities.shippedAgents.map(\.id), expected.map(\.0.id),
            "the documented agent list and the tested one must be the same list"
        )
        for row in expected {
            let capabilities = AgentCapabilities.of(row.0)
            XCTAssertEqual(capabilities.approvals, row.approvals, row.0.id)
            XCTAssertEqual(capabilities.questions, row.questions, row.0.id)
            XCTAssertEqual(capabilities.notifications, row.notifications, row.0.id)
            XCTAssertEqual(capabilities.instructions, row.instructions, row.0.id)
        }
    }

    /// The rung's whole point, stated as the one bit that differs across adapters: only an
    /// agent with an interceptable turn boundary can be handed a sentence it did not ask
    /// for.
    func testOnlyClaudeAndCodexCanBeInstructed() {
        XCTAssertTrue(AgentCapabilities.of(.claudeCode).instructions)
        XCTAssertTrue(AgentCapabilities.of(.codex).instructions)
        XCTAssertFalse(AgentCapabilities.of(.cursor).instructions)
        XCTAssertFalse(AgentCapabilities.of(.openCode).instructions)
    }

    /// A peer TapQ cannot name may still ask and announce — that is what legacy clients
    /// have always done — but nothing is ever sent into it.
    func testAnUnknownAgentIsInstructionFailClosed() {
        XCTAssertEqual(AgentCapabilities.of(.unknown), AgentCapabilities.unknown)
        XCTAssertEqual(AgentCapabilities.of(agentID: "some-third-party-shim"), .unknown)
        XCTAssertFalse(AgentCapabilities.unknown.instructions)
        XCTAssertTrue(AgentCapabilities.unknown.approvals)
    }
}
