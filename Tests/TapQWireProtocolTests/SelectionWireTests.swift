import XCTest
@testable import TapQWireProtocol
import TapQContracts

final class SelectionWireTests: XCTestCase {
    func testSelectionRequestDecodesFromJSON() throws {
        let json = #"{"type":"selection.request","token":"tok","session_id":"s1","request_id":"r1","question":"Pick a color","options":[{"label":"Red","description":"A warm color"},{"label":"Blue","description":"A cool color"}],"multi_select":false}"#
        let request = try BrokerRequest(from: Data(json.utf8))
        guard case .selection(let msg) = request else { return XCTFail("expected selection") }
        XCTAssertEqual(msg.token, "tok")
        XCTAssertEqual(msg.question, "Pick a color")
        XCTAssertEqual(msg.options.count, 2)
        XCTAssertEqual(msg.options[0].label, "Red")
        XCTAssertFalse(msg.multiSelect)
    }

    func testSelectionResponseEncodes() throws {
        let response = BrokerResponse.selection(indices: [1], labels: ["Blue"])
        let data = response.encoded()
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(decoded["selected_indices"]?.arrayValue?.first?.intValue, 1)
        XCTAssertEqual(decoded["selected_labels"]?.arrayValue?.first?.stringValue, "Blue")
    }

    func testSelectionResponseDecodesBack() throws {
        let response = BrokerResponse.selection(indices: [0, 2], labels: ["Red", "Green"])
        let data = response.encoded()
        let decoded = try JSONDecoder().decode(BrokerResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }

    // MARK: - free_text selection responses

    func testSelectionWithFreeTextEncodes() throws {
        let response = BrokerResponse.selection(indices: [], labels: [], freeText: "deploy to staging")
        let data = response.encoded()
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(decoded["selected_indices"]?.arrayValue?.count, 0)
        XCTAssertEqual(decoded["selected_labels"]?.arrayValue?.count, 0)
        XCTAssertEqual(decoded["free_text"]?.stringValue, "deploy to staging")
    }

    func testSelectionWithFreeTextRoundTrips() throws {
        let response = BrokerResponse.selection(indices: [], labels: [], freeText: "deploy to staging")
        let data = response.encoded()
        let decoded = try JSONDecoder().decode(BrokerResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }

    func testSelectionWithoutFreeTextIsByteIdenticalToV3() throws {
        // When freeText is nil, the encoded bytes must match the v3 shape exactly
        // (no free_text key present).
        let response = BrokerResponse.selection(indices: [1], labels: ["Blue"])
        let data = response.encoded()
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertNil(decoded["free_text"], "absent freeText must not produce a free_text key")
        XCTAssertEqual(decoded.count, 2, "only selected_indices and selected_labels")
    }

    func testSelectionWithBothLabelsAndFreeTextRoundTrips() throws {
        // Defensive: a response with both labels and freeText preserves both.
        let response = BrokerResponse.selection(indices: [0], labels: ["Red"], freeText: "red please")
        let data = response.encoded()
        let decoded = try JSONDecoder().decode(BrokerResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }

    func testV3SelectionBytesDecodeWithNilFreeText() throws {
        // Simulate a v3 broker response (no free_text key) and verify it decodes.
        let v3JSON = #"{"selected_indices":[0],"selected_labels":["Red"]}"#
        let decoded = try JSONDecoder().decode(BrokerResponse.self, from: Data(v3JSON.utf8))
        XCTAssertEqual(decoded, .selection(indices: [0], labels: ["Red"]))
    }
}
