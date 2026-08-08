import Foundation
import TapQOpenCodeAdapter
import TapQPOSIXBridgeClient
import TapQWireProtocol

// Thin executable edge for the TapQ OpenCode plugin: relay JSON in on stdin, one
// authenticated broker round-trip per relayed event, one decision object out on stdout.
// Decision and fail-open policy live in OpenCodeHookShim so they can be tested
// independently of the executable edge.

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let discovery = BrokerDiscovery()

enum OpenCodeShimVersionError: Error {
    case mismatch(app: Int, shim: Int)
    case unknownApprovalSource(String)
}

let result = OpenCodeHookShim.handle(stdinData: stdinData) { message, timeout in
    let (socketPath, token, appVersion, _) = try discovery.readDiscovery()

    let sourceRaw = message["approval_source"]?.stringValue
    let approvalSource = sourceRaw.flatMap(ApprovalSource.init(rawValue:))
    if let sourceRaw, approvalSource == nil {
        throw OpenCodeShimVersionError.unknownApprovalSource(sourceRaw)
    }

    // An OpenCode permission prompt carries the same policy significance as Claude's and
    // Codex's native PermissionRequest and therefore requires wire v3. Notification
    // traffic may temporarily bridge to a discovered v2 runtime.
    guard let outboundVersion = WireProtocol.outboundVersion(
        for: appVersion,
        approvalSource: approvalSource
    ) else {
        throw OpenCodeShimVersionError.mismatch(
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
