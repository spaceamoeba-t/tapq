import XCTest
import Foundation
@testable import TapQVoiceBackends
import TapQContracts

/// The tool half of the wire, in both directions.
///
/// The frames here are the contract with the service, and every assertion is a byte the
/// adapter would otherwise only discover was wrong against the live endpoint.
final class RealtimeToolMessagesTests: XCTestCase {
    private func object(_ frame: String) throws -> [String: Any] {
        let data = try XCTUnwrap(frame.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Declaring tools

    /// The declaration TapQ actually sends, rendered from the interaction layer's vocabulary
    /// rather than written out here — a tool that existed only in this encoding would be a
    /// tool nothing implements.
    func testToolsAreDeclaredOnTheSessionAsFunctionObjects() throws {
        let configuration = RealtimeSessionConfiguration(
            tools: VoiceIntentToolsFixture.declarations.map(RealtimeTool.init),
            toolChoice: "auto"
        )
        let frame = try RealtimeClientEvent.sessionUpdate(configuration).encodedFrame()
        let session = try XCTUnwrap(try object(frame)["session"] as? [String: Any])
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])

        XCTAssertEqual(session["tool_choice"] as? String, "auto")
        XCTAssertEqual(tools.count, VoiceIntentToolsFixture.declarations.count)
        for tool in tools {
            XCTAssertEqual(tool["type"] as? String, "function")
            XCTAssertNotNil(tool["name"] as? String)
            XCTAssertNotNil(tool["description"] as? String)
            let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["type"] as? String, "object")
            // An invented argument is a model describing an action TapQ cannot perform, and
            // the cheapest place to find that out is the service.
            XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        }
    }

    /// A parameter's kind, requiredness, and closed value set all survive the render — the
    /// three things that make the service refuse a call TapQ could not have executed.
    func testAParametersSchemaCarriesTypeRequirednessAndEnum() throws {
        let declaration = VoiceToolDeclaration(
            name: "query_status",
            description: "ask about state",
            parameters: [
                VoiceToolParameter(name: "kind", kind: .string, description: "which question",
                                   allowedValues: ["waiting", "changed"]),
                VoiceToolParameter(name: "detail", kind: .integer, description: "how much",
                                   required: false),
            ]
        )
        let frame = try RealtimeClientEvent
            .sessionUpdate(RealtimeSessionConfiguration(tools: [RealtimeTool(declaration)]))
            .encodedFrame()
        let session = try XCTUnwrap(try object(frame)["session"] as? [String: Any])
        let tool = try XCTUnwrap((session["tools"] as? [[String: Any]])?.first)
        let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])

        XCTAssertEqual(parameters["required"] as? [String], ["kind"])
        let kind = try XCTUnwrap(properties["kind"] as? [String: Any])
        XCTAssertEqual(kind["type"] as? String, "string")
        XCTAssertEqual(kind["enum"] as? [String], ["waiting", "changed"])
        let detail = try XCTUnwrap(properties["detail"] as? [String: Any])
        XCTAssertEqual(detail["type"] as? String, "integer")
        XCTAssertNil(detail["enum"])
    }

    /// GA's `session.update` is a merge, so an absent `tools` leaves whatever the session
    /// already had — which is what lets a turn-detection flip re-send the configuration
    /// without restating the tool set. An *empty* array is a different statement and is sent
    /// as one.
    func testAnAbsentToolSetIsOmittedAndAnEmptyOneIsSent() throws {
        let untouched = try RealtimeClientEvent
            .sessionUpdate(RealtimeSessionConfiguration()).encodedFrame()
        let session = try XCTUnwrap(try object(untouched)["session"] as? [String: Any])
        XCTAssertNil(session["tools"])
        XCTAssertNil(session["tool_choice"])

        let cleared = try RealtimeClientEvent
            .sessionUpdate(RealtimeSessionConfiguration(tools: [])).encodedFrame()
        let clearedSession = try XCTUnwrap(try object(cleared)["session"] as? [String: Any])
        XCTAssertEqual((clearedSession["tools"] as? [Any])?.count, 0)
    }

    // MARK: - Instructions

    /// Grounding is appended to the standing rules, never substituted for them: a session
    /// running on window context with the rules missing is one where a model is free to
    /// improvise about an approval.
    func testGroundingIsAppendedToTheStandingRules() {
        let grounded = RealtimeDefaults.instructions(grounding: "A TapQ window is open.")
        XCTAssertTrue(grounded.hasPrefix(RealtimeDefaults.baseInstructions))
        XCTAssertTrue(grounded.contains(RealtimeDefaults.toolPolicy))
        XCTAssertTrue(grounded.hasSuffix("A TapQ window is open."))

        let bare = RealtimeDefaults.instructions(grounding: nil)
        XCTAssertTrue(bare.contains(RealtimeDefaults.toolPolicy))
    }

    /// The standing rules say what silence is for. A model that treats "not sure" as a
    /// reason to pick the likelier reading of an authorization is the failure the whole tool
    /// path exists to remove, so the instruction is pinned rather than left to prose drift.
    func testTheToolPolicyNamesSilenceAsTheSafeAnswer() {
        let policy = RealtimeDefaults.toolPolicy.lowercased()
        XCTAssertTrue(policy.contains("never guess"))
        XCTAssertTrue(policy.contains("say nothing"))
        XCTAssertTrue(policy.contains("unambiguous"))

        // Narrowed 2026-08-28, and the narrowing is the load-bearing half: silence is safe
        // for *not acting*, and never for not answering. The two rules are pinned in one
        // test so a later edit cannot quietly restore the wider reading — a policy that
        // said only "say nothing when unsure" would take the audible refusal back out.
        XCTAssertTrue(policy.contains("must answer them out loud"))
        XCTAssertTrue(policy.contains("never leave a request they addressed to tapq "
                                      + "unanswered"))
        XCTAssertTrue(policy.contains("not directed at tapq"),
                      "the limit is as important as the rule: ambient speech stays quiet")
    }

    // MARK: - Answering a call

    /// The answer goes into the conversation, not out of band. The model is parked on a call
    /// it made *in* the conversation, and a result delivered anywhere else leaves it parked.
    func testAToolResultIsAConversationItem() throws {
        let frame = try RealtimeClientEvent
            .sendToolOutput(callID: "call_42", output: "Approved.")
            .encodedFrame()
        let decoded = try object(frame)
        let item = try XCTUnwrap(decoded["item"] as? [String: Any])

        XCTAssertEqual(decoded["type"] as? String, "conversation.item.create")
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_42")
        XCTAssertEqual(item["output"] as? String, "Approved.")
    }

    /// The item alone produces no speech. What the wearer hears about a tool is a sentence
    /// TapQ wrote, spoken verbatim on the scripted channel — a model narrating its own
    /// results would paraphrase refusals and announce everything else twice.
    func testAToolResultAsksForNoResponse() throws {
        let frame = try RealtimeClientEvent
            .sendToolOutput(callID: "call_42", output: "Approved.").encodedFrame()
        XCTAssertFalse(frame.contains("response.create"))
        XCTAssertEqual(RealtimeClientEvent.sendToolOutput(callID: "c", output: "o").wireType,
                       "conversation.item.create")
    }

    // MARK: - Reading a call

    /// Read from `response.output_item.done` and nowhere else. The service announces a call
    /// three times over, and two sources would execute one approval twice.
    func testAFunctionCallItemDecodesToACall() throws {
        let frame = RealtimeToolFrame.functionCall(
            callID: "call_7", name: "select_item", arguments: #"{"index":2}"#)
        XCTAssertEqual(try RealtimeServerEvent.decode(frame),
                       .functionCall(callID: "call_7", name: "select_item",
                                     argumentsJSON: #"{"index":2}"#))
    }

    /// Spoken output rides the same event and is already accounted for by the audio deltas.
    /// Only a function call is news.
    func testANonFunctionOutputItemIsIgnored() throws {
        let frame = #"{"type":"response.output_item.done","item":{"type":"message","id":"i1"}}"#
        XCTAssertEqual(try RealtimeServerEvent.decode(frame),
                       .unsupported("response.output_item.done"))
    }

    /// Absent arguments are the service's spelling for a tool that takes none — `approve` and
    /// `deny` are declared with no parameters — and are not a malformation.
    func testAParameterlessCallDecodesWithEmptyArguments() throws {
        let frame = #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"c1","name":"approve"}}"#
        XCTAssertEqual(try RealtimeServerEvent.decode(frame),
                       .functionCall(callID: "c1", name: "approve", argumentsJSON: ""))
    }

    /// Fail loud rather than execute half a call. A call with no id has no answer TapQ could
    /// send back and one with no name names no action; the alternative to ending the session
    /// is guessing which of TapQ's actions the wearer authorized.
    func testACallMissingItsIdOrNameIsMalformed() {
        let broken = [
            #"{"type":"response.output_item.done","item":{"type":"function_call","name":"approve"}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"c1"}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"","name":"approve"}}"#,
        ]
        for frame in broken {
            XCTAssertThrowsError(try RealtimeServerEvent.decode(frame),
                                 "a half-formed call decoded: \(frame)")
        }
    }
}

/// The interaction layer's declarations, restated here so this target does not depend on it.
///
/// Deliberately a fixture rather than an import: `TapQVoiceBackends` knows how to *spell* a
/// tool and must not know which tools exist, which is the boundary that keeps the action set
/// stated once, in the module that executes it.
enum VoiceIntentToolsFixture {
    static let declarations: [VoiceToolDeclaration] = [
        VoiceToolDeclaration(name: "approve", description: "the wearer authorized it"),
        VoiceToolDeclaration(name: "deny", description: "the wearer refused it"),
        VoiceToolDeclaration(
            name: "select_item",
            description: "the wearer chose an entry",
            parameters: [VoiceToolParameter(name: "index", kind: .integer,
                                            description: "one-based position")]
        ),
    ]
}

/// Tool frames as the service sends them.
enum RealtimeToolFrame {
    static func functionCall(callID: String, name: String, arguments: String) -> String {
        let item: [String: Any] = [
            "type": "function_call", "call_id": callID, "name": name, "arguments": arguments,
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: ["type": "response.output_item.done", "item": item],
            options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
