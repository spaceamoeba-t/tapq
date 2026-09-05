import Foundation
import TapQCodexAdapter
import TapQContracts
import TapQPOSIXBridgeClient
import TapQWireProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Thin executable edge for Codex lifecycle hooks: stdin JSON in, one authenticated broker
// round-trip per broker-backed event, documented hook JSON out. UserPromptSubmit reads
// discovery and opens a bounded EOF-only liveness connection, but sends no broker request
// or application data. Decision and fail-open policy live in CodexHookShim so they can be
// tested independently of the executable edge.

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let discovery = BrokerDiscovery()
// Codex keeps a hook's stderr to itself, so the shim's own record goes to the file the
// runtime's launcher names, when it names one — the same file the Claude shim writes.
let diagnosticSink: any TapQDiagnosticSink = AppendingFileDiagnosticSink(
    environment: ProcessInfo.processInfo.environment, key: "TAPQ_HOOK_LOG"
) ?? NoOpTapQDiagnosticSink()

enum CodexShimVersionError: Error {
    case mismatch(app: Int, shim: Int)
    case unknownApprovalSource(String)
}

let result = CodexHookShim.handle(stdinData: stdinData, steeringEnabled: {
    // Steering injects only when the broker is live, its wire version is compatible,
    // and the runtime was explicitly launched with steering enabled. Any doubt is silent.
    guard let discovered = try? discovery.readLiveDiscovery(),
          WireProtocol.outboundVersion(
              for: discovered.protocolVersion,
              approvalSource: nil
          ) != nil else { return false }
    return discovered.steeringEnabled
}, voiceSessionEnabled: {
    // Same liveness discipline as steering, for a stronger reason: this answer decides
    // whether a Stop hook *waits*, and a record left behind by a killed runtime would park
    // it against a broker nobody is listening on. Fail-closed all the way down.
    discovery.liveVoiceSessionEnabled()
}, diagnosticSink: diagnosticSink) { message, timeout in
    let (socketPath, token, appVersion, _) = try discovery.readDiscovery()

    let sourceRaw = message["approval_source"]?.stringValue
    let approvalSource = sourceRaw.flatMap(ApprovalSource.init(rawValue:))
    if let sourceRaw, approvalSource == nil {
        throw CodexShimVersionError.unknownApprovalSource(sourceRaw)
    }

    // Codex PermissionRequest has the same policy significance as Claude's native
    // PermissionRequest and therefore requires wire v3. Stop/notification traffic may
    // temporarily bridge to a discovered v2 runtime. The message type is passed too, so a
    // type that postdates the broker — `instruction.wait` against a v5 runtime — fails
    // open here instead of earning an "unknown message type" over the socket.
    guard let outboundVersion = WireProtocol.outboundVersion(
        for: appVersion,
        approvalSource: approvalSource,
        messageType: message["type"]?.stringValue
    ) else {
        throw CodexShimVersionError.mismatch(
            app: appVersion ?? -1,
            shim: WireProtocol.version
        )
    }

    var authenticated = message
    authenticated["token"] = .string(token)
    authenticated["protocol_version"] = .number(Double(outboundVersion))
    if outboundVersion == WireProtocol.legacyBridgeVersion {
        authenticated.removeValue(forKey: "approval_source")
    }

    let payload = try JSONEncoder().encode(authenticated)
    return try UnixSocketClient.request(payload, socketPath: socketPath, timeout: timeout)
}

if let stdout = result.stdout {
    print(stdout)
}
exit(result.exitCode)
