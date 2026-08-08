import Foundation
import TapQCursorAdapter
import TapQPOSIXBridgeClient
import TapQWireProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Thin executable edge for Cursor agent hooks: stdin JSON in, one authenticated broker
// round-trip per broker-backed event, documented hook JSON out. Decision and fail-open
// policy live in CursorHookShim so they can be tested independently of this edge.

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let discovery = BrokerDiscovery()

enum CursorShimVersionError: Error {
    case mismatch(app: Int, shim: Int)
    case unknownApprovalSource(String)
}

let result = CursorHookShim.handle(stdinData: stdinData) { message, timeout in
    let (socketPath, token, appVersion, _) = try discovery.readDiscovery()

    let sourceRaw = message["approval_source"]?.stringValue
    let approvalSource = sourceRaw.flatMap(ApprovalSource.init(rawValue:))
    if let sourceRaw, approvalSource == nil {
        throw CursorShimVersionError.unknownApprovalSource(sourceRaw)
    }

    // Cursor's approval hooks are strict pre-tool gates, the same policy class as Claude's
    // PreToolUse, so they may bridge to a discovered legacy v2 runtime.
    guard let outboundVersion = WireProtocol.outboundVersion(
        for: appVersion,
        approvalSource: approvalSource
    ) else {
        throw CursorShimVersionError.mismatch(
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
