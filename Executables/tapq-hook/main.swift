import Foundation
import TapQPOSIXBridgeClient
import TapQWireProtocol
import TapQClaudeAdapter
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Compiled `tapq-hook` shim. Claude Code runs this for PreToolUse, PermissionRequest,
// Notification, Stop, and UserPromptSubmit; it forwards broker-backed events over the Unix
// socket and writes each hook's expected stdout. All decision logic (and fail-open behavior)
// lives in `HookShim`; this file is just the I/O edge: real stdin in, socket round-trip,
// stdout + exit out.

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let discovery = BrokerDiscovery()

enum ShimVersionError: Error {
    case mismatch(app: Int, shim: Int)
    case unknownApprovalSource(String)
}

let result = HookShim.handle(stdinData: stdinData, steeringEnabled: {
    // Steering injects only when the discovery publisher is still live, speaks a
    // safely bridgeable wire version, and the user has the flag on. Anything else →
    // inject nothing.
    guard let discovered = try? discovery.readLiveDiscovery(),
          WireProtocol.outboundVersion(
              for: discovered.protocolVersion,
              approvalSource: nil
          ) != nil else { return false }
    return discovered.steeringEnabled
}) { message, timeout in
    let (socketPath, token, appVersion, _) = try discovery.readDiscovery()

    let sourceRaw = message["approval_source"]?.stringValue
    let approvalSource = sourceRaw.flatMap(ApprovalSource.init(rawValue:))
    if let sourceRaw, approvalSource == nil {
        throw ShimVersionError.unknownApprovalSource(sourceRaw)
    }

    // Wire v2 is safe for unchanged legacy events, including strict PreToolUse. Native
    // PermissionRequest requires v3 because a v2 broker cannot distinguish its source
    // and could apply legacy auto-mode behavior. Unsupported combinations fail open.
    guard let outboundVersion = WireProtocol.outboundVersion(
        for: appVersion,
        approvalSource: approvalSource
    ) else {
        throw ShimVersionError.mismatch(app: appVersion ?? -1, shim: WireProtocol.version)
    }
    var authed = message
    authed["token"] = .string(token)
    authed["protocol_version"] = .number(Double(outboundVersion))
    if outboundVersion == WireProtocol.legacyBridgeVersion {
        authed.removeValue(forKey: "approval_source")
    }
    let payload = try JSONEncoder().encode(authed)
    return try UnixSocketClient.request(payload, socketPath: socketPath, timeout: timeout)
}

if let stdout = result.stdout {
    print(stdout)
}
exit(result.exitCode)
