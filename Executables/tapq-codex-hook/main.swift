import Foundation
import TapQCodexAdapter
import TapQPOSIXBridgeClient
import TapQWireProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Thin executable edge for Codex lifecycle hooks: stdin JSON in, one authenticated broker
// round-trip per supported event, documented hook JSON out. Decision and fail-open policy
// live in CodexHookShim so they can be tested without a real socket.

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let discovery = BrokerDiscovery()

enum CodexShimVersionError: Error {
    case mismatch(app: Int, shim: Int)
    case unknownApprovalSource(String)
}

let result = CodexHookShim.handle(stdinData: stdinData) { message, timeout in
    let (socketPath, token, appVersion, _) = try discovery.readDiscovery()

    let sourceRaw = message["approval_source"]?.stringValue
    let approvalSource = sourceRaw.flatMap(ApprovalSource.init(rawValue:))
    if let sourceRaw, approvalSource == nil {
        throw CodexShimVersionError.unknownApprovalSource(sourceRaw)
    }

    // Codex PermissionRequest has the same policy significance as Claude's native
    // PermissionRequest and therefore requires wire v3. Stop/notification traffic may
    // temporarily bridge to a discovered v2 runtime.
    guard let outboundVersion = WireProtocol.outboundVersion(
        for: appVersion,
        approvalSource: approvalSource
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
