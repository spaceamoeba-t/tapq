import Foundation
import XCTest
@testable import TapQContracts

/// The kernel's `diagnostics.log` (P2-4): no debug lines, one rotated file, bounded.
final class DiagnosticsLogTests: XCTestCase {
    private func scratchPath() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-sink-\(UUID().uuidString).log").path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".1")
        }
        return path
    }

    private let event = TapQDiagnosticEvent(category: "c", name: "n")

    /// One line of `event` as this process writes it: the timestamp's width is fixed.
    private var lineLength: Int {
        AppendingFileDiagnosticSink.formatted(
            event, at: Date(), processID: ProcessInfo.processInfo.processIdentifier).utf8.count
    }

    private func lines(_ path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Two writers of one file (a notes run beside the recording it reads, 2026-10-19):
    /// `O_APPEND` puts every line at the end as the file then is, so neither writes over the
    /// other's. Before, each wrote from where it had opened the file.
    func testTwoWritersOfOneFileKeepEachOthersLines() throws {
        let path = scratchPath()
        let first = AppendingFileDiagnosticSink(path: path)
        let second = AppendingFileDiagnosticSink(path: path)
        first.record(.init(category: "recording", name: "one"))
        second.record(.init(category: "notes", name: "two"))
        first.record(.init(category: "recording", name: "three"))
        second.record(.init(category: "notes", name: "four"))
        XCTAssertEqual(try lines(path).map { String($0.split(separator: " ").last ?? "") },
                       ["one", "two", "three", "four"])
    }

    func testDebugNeverReachesTheFile() throws {
        let path = scratchPath()
        let sink = AppendingFileDiagnosticSink(path: path)
        sink.record(.init(category: "vad", name: "frame", level: .debug))
        sink.record(.init(category: "kernel", name: "run.fresh", fields: ["installed": "claude"]))
        sink.record(.init(category: "kernel", name: "late", level: .warning))
        let written = try lines(path)
        XCTAssertEqual(written.count, 2)
        XCTAssertTrue(written[0].hasSuffix("[info][kernel] run.fresh installed=claude"), written[0])
        XCTAssertTrue(written[1].hasSuffix("[warning][kernel] late"), written[1])
        XCTAssertTrue(written[0].contains("[pid \(ProcessInfo.processInfo.processIdentifier)]"))
    }

    /// Past the limit the file becomes `.1`, replacing the previous one, and a new one starts.
    func testTheFileRotatesIntoOneArchive() throws {
        let path = scratchPath()
        let sink = AppendingFileDiagnosticSink(path: path, rotationLimit: lineLength * 2 + 10)
        for _ in 0..<7 { sink.record(event) }
        XCTAssertEqual(try lines(path).count, 1)
        XCTAssertEqual(try lines(path + ".1").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".2"))
    }

    /// The file a run starts with counts toward the limit.
    func testAnExistingFileCountsTowardTheLimit() throws {
        let path = scratchPath()
        try "earlier run\n".write(toFile: path, atomically: true, encoding: .utf8)
        let sink = AppendingFileDiagnosticSink(path: path, rotationLimit: lineLength + 11)
        sink.record(event)
        XCTAssertEqual(try lines(path + ".1"), ["earlier run"])
        XCTAssertEqual(try lines(path).count, 1)
    }

    func testTheLineFormatIsStable() {
        let line = AppendingFileDiagnosticSink.formatted(
            .init(category: "C", name: "n", level: .warning, fields: ["b": "2", "a": "1"]),
            at: Date(timeIntervalSince1970: 0), processID: 7)
        XCTAssertEqual(line, "1970-01-01T00:00:00.000Z [pid 7][warning][C] n a=1 b=2\n")
    }

    func testAnUnwritablePathLosesTheLineOnly() {
        let sink = AppendingFileDiagnosticSink(path: "/nonexistent-dir/tapq/diagnostics.log")
        sink.record(.init(category: "C", name: "n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.path))
    }
}
