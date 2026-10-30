import Foundation
import TapQKernel
import XCTest
@testable import TapQKernelCodex

final class CodexLaunchSpecTests: XCTestCase {
    func testEnvironmentDropsTapQVariablesAndTheOpenAIKeyOnly() {
        let parent = [
            "PATH": "/usr/bin", "HOME": "/Users/user", "CODEX_HOME": "/Users/user/.codex",
            "HTTPS_PROXY": "http://proxy:8080", "CODEX_API_KEY": "kept",
            "OPENAI_API_KEY": "test-key", "TAPQ_OPENAI_API_KEY": "test-key", "TAPQ_DEBUG": "1",
            "OPENAI_BASE_URL": "kept",
        ]
        XCTAssertEqual(CodexLaunchSpec.sanitized(parent), [
            "PATH": "/usr/bin", "HOME": "/Users/user", "CODEX_HOME": "/Users/user/.codex",
            "HTTPS_PROXY": "http://proxy:8080", "CODEX_API_KEY": "kept", "OPENAI_BASE_URL": "kept",
        ])
    }

    func testSpecRunsTheAppServerInTheWorkspace() {
        let workspace = URL(fileURLWithPath: "/work/project")
        let spec = CodexLaunchSpec(executablePath: "/opt/bin/codex", workspace: workspace,
                                   environment: ["TAPQ_X": "1", "PATH": "/bin"])
        XCTAssertEqual(spec.arguments, ["app-server"])
        XCTAssertEqual(spec.environment, ["PATH": "/bin"])
        XCTAssertEqual(spec.workspace, workspace)
    }

    func testVersionOutputParses() {
        XCTAssertEqual(CodexVersions.parse(versionOutput: "codex-cli 0.161.0\n"), "0.161.0")
        XCTAssertEqual(CodexVersions.parse(versionOutput: "codex 0.161.4"), "0.161.4")
        XCTAssertEqual(CodexVersions.parse(versionOutput: "codex-cli 0.162.0-alpha.20"), "0.162.0-alpha.20")
        XCTAssertNil(CodexVersions.parse(versionOutput: "claude 2.1.283"))
        XCTAssertNil(CodexVersions.parse(versionOutput: "codex-cli"))
        XCTAssertNil(CodexVersions.parse(versionOutput: ""))
    }

    func testUserAgentVersionParses() {
        XCTAssertEqual(CodexVersions.parse(userAgent: "codex_app_server/0.161.0 (Mac OS 15.2.0; arm64) unknown"),
                       "0.161.0")
        XCTAssertEqual(CodexVersions.parse(userAgent: "codex_vscode/0.161.2"), "0.161.2")
        XCTAssertNil(CodexVersions.parse(userAgent: "codex_app_server"))
        XCTAssertNil(CodexVersions.parse(userAgent: "codex_app_server/ (Mac OS)"))
    }

    func testSupportedRangeIsTheWholeOf0161() {
        let range = CodexVersions.supported
        XCTAssertTrue(range.contains("0.161.0"))
        XCTAssertTrue(range.contains("0.161.9"))
        XCTAssertFalse(range.contains("0.160.3"))
        XCTAssertFalse(range.contains("0.162.0"))
        XCTAssertFalse(range.contains("0.162.0-alpha.20"))
        XCTAssertEqual(range.refusal(for: .codex, found: "0.162.0"),
                       "Codex 0.162.0 is not supported. TapQ supports 0.161.0 through 0.161.x.")
    }
}
