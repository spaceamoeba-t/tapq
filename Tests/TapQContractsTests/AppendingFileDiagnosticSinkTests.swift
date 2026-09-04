import Foundation
import XCTest
@testable import TapQContracts

final class AppendingFileDiagnosticSinkTests: XCTestCase {
    private func scratchPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-sink-\(UUID().uuidString).log").path
    }

    func testEveryLevelIsAppendedAsOneLineWithClockAndProcess() throws {
        let path = scratchPath()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let sink = AppendingFileDiagnosticSink(path: path)
        sink.record(.init(category: "ClaudeHook", name: "handle", level: .debug,
                          fields: ["event": "Stop", "tool": ""]))
        sink.record(.init(category: "ClaudeHook", name: "stop_question.no_reply",
                          fields: ["attempts": "4"]))
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "one line per event, debug included")
        XCTAssertTrue(lines[0].hasSuffix("[debug][ClaudeHook] handle event=Stop tool="), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("[info][ClaudeHook] stop_question.no_reply attempts=4"), lines[1])
        let pid = "[pid \(ProcessInfo.processInfo.processIdentifier)]"
        XCTAssertTrue(lines.allSatisfy { $0.contains(pid) })
        XCTAssertTrue(lines.allSatisfy { $0.count > pid.count + 30 }, "a timestamp leads each line")
    }

    func testTheLineFormatIsStable() {
        let line = AppendingFileDiagnosticSink.formatted(
            .init(category: "C", name: "n", level: .warning, fields: ["b": "2", "a": "1"]),
            at: Date(timeIntervalSince1970: 0), processID: 7
        )
        XCTAssertEqual(line, "1970-01-01T00:00:00.000Z [pid 7][warning][C] n a=1 b=2\n")
    }

    func testTheEnvironmentNamesTheFileOrThereIsNoSink() {
        XCTAssertNil(AppendingFileDiagnosticSink(environment: [:], key: "TAPQ_HOOK_LOG"))
        XCTAssertNil(AppendingFileDiagnosticSink(environment: ["TAPQ_HOOK_LOG": "  "], key: "TAPQ_HOOK_LOG"))
        XCTAssertEqual(
            AppendingFileDiagnosticSink(environment: ["TAPQ_HOOK_LOG": "/tmp/x.log"], key: "TAPQ_HOOK_LOG")?.path,
            "/tmp/x.log"
        )
    }

    func testAnUnwritablePathIsIgnored() {
        let sink = AppendingFileDiagnosticSink(path: "/nonexistent-dir/tapq/hook.log")
        sink.record(.init(category: "C", name: "n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.path))
    }
}
