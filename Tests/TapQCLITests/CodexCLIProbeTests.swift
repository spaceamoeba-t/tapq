import XCTest
@testable import TapQCLI

final class CodexCLIProbeTests: XCTestCase {
    func testProbeParsesVersionAndRequestedFeatures() {
        let status = CodexCLIProbe.probe { arguments -> CodexCLICommandResult in
            switch arguments {
            case ["--version"]:
                return .completed(
                    status: 0,
                    standardOutput: "codex-cli 0.146.0\n",
                    standardError: ""
                )
            case ["features", "list"]:
                return .completed(
                    status: 0,
                    standardOutput: """
                    hooks                                 stable             true
                    default_mode_request_user_input       under development  false
                    """,
                    standardError: ""
                )
            default:
                XCTFail("Unexpected Codex arguments: \(arguments)")
                return .unavailable
            }
        }

        XCTAssertEqual(status.version, "0.146.0")
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.hooks, .enabled(stage: "stable"))
        XCTAssertEqual(
            status.defaultModeRequestUserInput,
            .disabled(stage: "under development")
        )
    }

    func testResolvedCodexWhoseVersionProbeFailsIsNotReportedAsMissing() {
        var calls: [[String]] = []

        let status = CodexCLIProbe.probe(executablePath: "/opt/codex/bin/codex") { arguments in
            calls.append(arguments)
            return .unavailable
        }

        XCTAssertEqual(calls, [["--version"]])
        XCTAssertEqual(status.availability, .probeFailed)
        XCTAssertEqual(status.executablePath, "/opt/codex/bin/codex")
        XCTAssertFalse(status.isAvailable)
    }

    func testMissingCodexDoesNotAttemptAnyProbe() {
        var callCount = 0

        let status = CodexCLIProbe.probe(executableWasResolved: false) { _ in
            callCount += 1
            return .unavailable
        }

        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(status, .notFound)
    }

    func testMalformedSuccessfulOutputProducesUnknownDiagnostics() {
        let status = CodexCLIProbe.probe { arguments in
            if arguments == ["--version"] {
                return .completed(
                    status: 0,
                    standardOutput: "unexpected version output",
                    standardError: ""
                )
            }
            return .completed(
                status: 0,
                standardOutput: "hooks stable perhaps\ndefault_mode_request_user_input ???",
                standardError: ""
            )
        }

        XCTAssertTrue(status.isAvailable)
        XCTAssertNil(status.version)
        XCTAssertEqual(status.hooks, .unknown)
        XCTAssertEqual(status.defaultModeRequestUserInput, .unknown)
    }

    func testFeatureParserRejectsUnrecognizedUnboundedAndControlBearingStages() {
        let oversizedStage = String(repeating: "stage", count: 10_000)

        XCTAssertEqual(
            CodexCLIProbe.parseFeature(named: "hooks", from: "hooks \(oversizedStage) true"),
            .unknown
        )
        XCTAssertEqual(
            CodexCLIProbe.parseFeature(
                named: "hooks",
                from: "hooks stable\u{001B}[2J true"
            ),
            .unknown
        )
        XCTAssertEqual(
            CodexCLIProbe.parseFeature(named: "hooks", from: "hooks experimental false"),
            .disabled(stage: "experimental")
        )
        XCTAssertEqual(
            CodexCLIProbe.parseFeature(named: "hooks", from: "hooks removed false"),
            .disabled(stage: "removed")
        )
        XCTAssertEqual(
            CodexCLIProbe.parseFeature(named: "hooks", from: "hooks deprecated false"),
            .disabled(stage: "deprecated")
        )
    }

    func testVersionParserAcceptsOnlyBoundedASCIIPreReleaseAndBuildMetadata() {
        XCTAssertEqual(
            CodexCLIProbe.parseVersion(from: "codex-cli 0.146.0-beta.1+build-7"),
            "0.146.0-beta.1+build-7"
        )
        XCTAssertNil(
            CodexCLIProbe.parseVersion(from: "codex-cli 0.146.0+\u{001B}[2J")
        )
        XCTAssertNil(
            CodexCLIProbe.parseVersion(from: "codex-cli 0.146.0-beta\u{202E}txt")
        )
        XCTAssertNil(
            CodexCLIProbe.parseVersion(
                from: "codex-cli 0.146.0+\(String(repeating: "a", count: 256))"
            )
        )
        XCTAssertNil(
            CodexCLIProbe.parseVersion(from: "codex-cli 0.146.0+build/unsafe")
        )
    }

    func testFailedFeatureCommandKeepsDetectedVersionAndUnknownFeatures() {
        let status = CodexCLIProbe.probe { arguments in
            if arguments == ["--version"] {
                return .completed(
                    status: 0,
                    standardOutput: "codex 1.2.3-beta.1",
                    standardError: ""
                )
            }
            return .completed(status: 64, standardOutput: "", standardError: "unsupported")
        }

        XCTAssertEqual(status.version, "1.2.3-beta.1")
        XCTAssertEqual(status.hooks, .unknown)
        XCTAssertEqual(status.defaultModeRequestUserInput, .unknown)
    }

    func testTestedLifecycleFloorComparisonBoundaries() {
        XCTAssertEqual(CodexCLIProbe.isBelowTestedLifecycleFloor("0.142.4"), true)
        XCTAssertEqual(CodexCLIProbe.isBelowTestedLifecycleFloor("0.142.5-beta.1"), true)
        XCTAssertEqual(CodexCLIProbe.isBelowTestedLifecycleFloor("0.142.5"), false)
        XCTAssertEqual(CodexCLIProbe.isBelowTestedLifecycleFloor("0.146.0"), false)
        XCTAssertNil(CodexCLIProbe.isBelowTestedLifecycleFloor("development"))
        XCTAssertNil(CodexCLIProbe.isBelowTestedLifecycleFloor(""))
        XCTAssertNil(CodexCLIProbe.isBelowTestedLifecycleFloor("0.142.5-"))
    }

    func testProcessRunnerDrainsOutputLargerThanAPipeBuffer() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: shell.path))
        let result = CodexCLIProcessRunner.run(
            executableURL: shell,
            arguments: [
                "-c",
                "i=0; while [ \"$i\" -lt 20000 ]; do printf 0123456789; i=$((i+1)); done",
            ],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            timeout: 3
        )

        guard case .completed(let status, let output, let error) = result else {
            return XCTFail("Expected the bounded process to complete")
        }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output.utf8.count, 200_000)
        XCTAssertEqual(error, "")
    }

    func testProcessRunnerRetainsAtMostTheOutputLimitWhileContinuingToDrain() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let yes = URL(fileURLWithPath: "/usr/bin/yes")
        let head = URL(fileURLWithPath: "/usr/bin/head")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: shell.path))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: yes.path))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: head.path))
        let generatedByteCount = CodexCLIProcessRunner.maximumCapturedOutputBytes + 262_144
        for _ in 0..<3 {
            let result = CodexCLIProcessRunner.run(
                executableURL: shell,
                arguments: [
                    "-c",
                    "yes O | head -c \(generatedByteCount); "
                        + "yes E | head -c \(generatedByteCount) >&2",
                ],
                environment: ["PATH": "/usr/bin:/bin"],
                currentDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                timeout: 3
            )

            guard case .completed(let status, let output, let error) = result else {
                return XCTFail("Expected oversized stdout and stderr to be fully drained")
            }
            XCTAssertEqual(status, 0)
            XCTAssertEqual(output.utf8.count, CodexCLIProcessRunner.maximumCapturedOutputBytes)
            XCTAssertEqual(error.utf8.count, CodexCLIProcessRunner.maximumCapturedOutputBytes)
            XCTAssertTrue(output.allSatisfy { $0 == "O" || $0 == "\n" })
            XCTAssertTrue(error.allSatisfy { $0 == "E" || $0 == "\n" })
        }
    }

    func testProcessRunnerClosesPipesRetainedByAnExitedParentsDescendant() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: shell.path))
        let descriptorCountBeforeRun = try openFileDescriptorCount()
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tapq-codex-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let markerURL = temporaryDirectory.appendingPathComponent("pipe-state")
        // swift-corelibs-foundation gives the child a private process-tracking socket. Close
        // unrelated inherited descriptors in the descendant so this test isolates stdout/stderr
        // pipe retention instead of waiting for Foundation's private socket to reach EOF.
        let closeUnrelatedDescriptors = "descriptor_root=/proc/self/fd; "
            + "[ -d \"$descriptor_root\" ] || descriptor_root=/dev/fd; "
            + "for descriptor_path in \"$descriptor_root\"/*; "
            + "do descriptor=${descriptor_path##*/}; "
            + "case \"$descriptor\" in 0|1|2|*[!0-9]*) ;; "
            + "*) eval \"exec ${descriptor}>&-\" ;; esac; done"
        let start = Date()
        let result = CodexCLIProcessRunner.run(
            executableURL: shell,
            arguments: [
                "-c",
                "(\(closeUnrelatedDescriptors); sleep 2; "
                    + "printf retained > \"$TAPQ_PIPE_MARKER\") & kill -9 $$",
            ],
            environment: [
                "PATH": "/usr/bin:/bin",
                "TAPQ_PIPE_MARKER": markerURL.path,
            ],
            currentDirectory: temporaryDirectory,
            timeout: 3
        )

        XCTAssertEqual(result, .unavailable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertLessThanOrEqual(try openFileDescriptorCount(), descriptorCountBeforeRun)

        let deadline = Date().addingTimeInterval(3)
        var marker: String?
        while Date() < deadline, marker == nil {
            marker = try? String(contentsOf: markerURL, encoding: .utf8)
            if marker == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertEqual(marker, "retained")
    }

    func testProcessRunnerBoundsAWedgedCommand() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: shell.path))
        for _ in 0..<3 {
            let start = Date()
            let result = CodexCLIProcessRunner.run(
                executableURL: shell,
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                environment: ["PATH": "/usr/bin:/bin"],
                currentDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                timeout: 0.05
            )

            XCTAssertEqual(result, .unavailable)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        }
    }

    func testResolvedProcessRunnerPassesOnlyTheMinimalDiagnosticEnvironment() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tapq-codex-environment-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = temporaryDirectory.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        printf '%s|%s|%s|%s|%s' "${OPENAI_API_KEY-unset}" "${AWS_SECRET_ACCESS_KEY-unset}" "$NO_COLOR" "$TERM" "$CODEX_HOME"
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let path = temporaryDirectory.path + ":/usr/bin:/bin"
        let codexHome = temporaryDirectory.appendingPathComponent("codex-home").path
        let runner = try XCTUnwrap(CodexCLIProcessRunner.resolve(
            environment: [
                "PATH": path,
                "HOME": temporaryDirectory.path,
                "CODEX_HOME": codexHome,
                "LANG": "C",
                "OPENAI_API_KEY": "must-not-reach-child",
                "AWS_SECRET_ACCESS_KEY": "must-not-reach-child",
                "SSH_AUTH_SOCK": "/tmp/private-agent",
                "TAPQ_INTERNAL_SECRET": "must-not-reach-child",
                "NO_COLOR": "host-value-is-overridden",
                "TERM": "xterm-secret-capability",
            ],
            currentDirectory: temporaryDirectory
        ))

        XCTAssertEqual(runner.executableURL.path, executableURL.path)
        XCTAssertEqual(
            Set(runner.environment.keys),
            Set(["PATH", "HOME", "CODEX_HOME", "LANG", "NO_COLOR", "TERM"])
        )
        guard case .completed(let status, let output, let error) =
                runner.run(arguments: ["--version"]) else {
            return XCTFail("Expected the resolved probe executable to run")
        }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output, "unset|unset|1|dumb|\(codexHome)")
        XCTAssertEqual(error, "")
    }

    private func openFileDescriptorCount() throws -> Int {
        #if os(Linux)
        let descriptorDirectory = "/proc/self/fd"
        #else
        let descriptorDirectory = "/dev/fd"
        #endif
        return try FileManager.default.contentsOfDirectory(atPath: descriptorDirectory).count
    }
}
