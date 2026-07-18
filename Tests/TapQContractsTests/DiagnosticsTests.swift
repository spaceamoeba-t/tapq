import XCTest
@testable import TapQContracts

final class DiagnosticsTests: XCTestCase {
    func testDiagnosticEventCarriesOnlyGenericFields() {
        let event = TapQDiagnosticEvent(
            category: "Detection",
            name: "gesture.detected",
            fields: ["gesture": "nod"])
        XCTAssertEqual(event.category, "Detection")
        XCTAssertEqual(event.fields["gesture"], "nod")
        NoOpTapQDiagnosticSink().record(event)
    }
}
