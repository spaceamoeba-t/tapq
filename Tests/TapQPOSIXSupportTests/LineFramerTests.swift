import Foundation
import XCTest
@testable import TapQPOSIXSupport

final class LineFramerTests: XCTestCase {
    func testLinesAreRebuiltAcrossChunkBoundaries() {
        var framer = LineFramer()
        XCTAssertEqual(framer.push(Data(##"{"a":1}"##.utf8)), [])
        XCTAssertEqual(framer.push(Data("\n{\"b\":".utf8)), [##"{"a":1}"##])
        XCTAssertEqual(framer.push(Data("2}\n{\"c\":3}\n".utf8)),
                       [##"{"b":2}"##, ##"{"c":3}"##])
        XCTAssertNil(framer.flush())
    }

    func testAFinalUnterminatedLineIsDeliveredAtEOF() {
        var framer = LineFramer()
        XCTAssertEqual(framer.push(Data("tail".utf8)), [])
        XCTAssertEqual(framer.flush(), "tail")
        XCTAssertNil(framer.flush())
    }

    func testCarriageReturnsAreStripped() {
        var framer = LineFramer()
        XCTAssertEqual(framer.push(Data("one\r\ntwo\n".utf8)), ["one", "two"])
    }

    /// A multi-byte character split across two reads decodes whole.
    func testAUTF8SequenceSplitAcrossChunksDecodesWhole() {
        var framer = LineFramer()
        let bytes = Array("é\n".utf8)
        XCTAssertEqual(framer.push(Data(bytes[0..<1])), [])
        XCTAssertEqual(framer.push(Data(bytes[1...])), ["é"])
    }
}
