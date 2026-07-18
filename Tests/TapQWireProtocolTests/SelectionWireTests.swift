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
}
