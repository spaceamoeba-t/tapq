import XCTest
@testable import TapQVoiceBackends
import TapQContracts

/// RB6: every session TapQ opens carries the same standing rules.
///
/// The constant is asserted on the wire rather than on the struct because the failure this
/// guards is a composition one — a construction site that builds its configuration without
/// the instructions — and only the frame the service actually receives can catch that.
@MainActor
final class RealtimeBaseInstructionsTests: XCTestCase {
    func testSessionUpdateCarriesTheBaseInstructions() async throws {
        let server = ScriptedRealtimeServer()
        let backend = OpenAIRealtimeVoiceBackend(transport: server, timeout: 1)

        try await backend.open { _ in }

        XCTAssertEqual(server.sentTypes, ["session.update"])
        XCTAssertEqual(
            server.sessionConfiguration?["instructions"] as? String,
            RealtimeDefaults.instructions(grounding: nil),
            "the first frame declares the tools, so it must carry the policy governing them too"
        )
    }

    /// The rules are short enough to be a system prompt and not a policy document (RB6
    /// caps them at 50 words), and they name both jobs the model has.
    func testBaseInstructionsStayShortAndNameBothJobs() async {
        let words = RealtimeDefaults.baseInstructions
            .split(whereSeparator: { $0.isWhitespace })
        XCTAssertLessThanOrEqual(words.count, 50)
        XCTAssertTrue(RealtimeDefaults.baseInstructions.contains("verbatim"))
        XCTAssertTrue(RealtimeDefaults.baseInstructions.contains("only the context"))
    }

    /// A caller that supplies its own configuration gets exactly what it asked for. The
    /// adapter forces turn detection off and nothing else — pinning a caller's system
    /// prompt would make an embedder's session TapQ's session.
    func testCallerSuppliedConfigurationKeepsItsOwnInstructions() async throws {
        let server = ScriptedRealtimeServer()
        let backend = OpenAIRealtimeVoiceBackend(
            transport: server,
            configuration: RealtimeSessionConfiguration(instructions: "be terse"),
            timeout: 1
        )

        try await backend.open { _ in }

        XCTAssertEqual(server.sessionConfiguration?["instructions"] as? String, "be terse")
    }
}
