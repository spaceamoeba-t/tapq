import XCTest
@testable import TapQVoiceBackends
import TapQContracts

/// What the factory promises, in the order the promises matter:
///
/// 1. The default provider is a pass-through — no wrapper, no policy, no cost.
/// 2. An explicitly requested cloud backend with no credentials fails at startup rather
///    than quietly serving the on-device one.
/// 3. Everything the cloud path composes has the on-device stack underneath it.
@MainActor
final class VoiceBackendFactoryTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.name)
        }
    }

    /// Records what the realtime seam was handed, and hands back a fake so no test builds a
    /// WebSocket transport.
    @MainActor
    private final class RealtimeSpy {
        private(set) var apiKeys: [String] = []
        private(set) var sinks: [any TapQDiagnosticSink] = []
        let backend: ScriptedVoiceBackend

        init(backend: ScriptedVoiceBackend? = nil) {
            self.backend = backend ?? ScriptedVoiceBackend(name: "realtime")
        }

        func make(apiKey: String, sink: any TapQDiagnosticSink) throws -> any VoiceBackend {
            apiKeys.append(apiKey)
            sinks.append(sink)
            return backend
        }
    }

    // MARK: - Provider vocabulary

    /// The raw values are the CLI spellings, so a renamed case is a renamed flag and this
    /// test is the thing that says so out loud.
    func testProviderRawValuesAreTheFlagSpellings() {
        XCTAssertEqual(VoiceBackendProvider.allCases.map(\.rawValue),
                       ["apple", "openai-realtime"])
        XCTAssertEqual(VoiceBackendProvider(rawValue: "openai-realtime"), .openaiRealtime)
        XCTAssertNil(VoiceBackendProvider(rawValue: "openai_realtime"))
    }

    func testOnlyTheNonDefaultProviderReportsAStatusLine() {
        XCTAssertNil(VoiceBackendProvider.apple.statusDescription)
        XCTAssertEqual(VoiceBackendProvider.openaiRealtime.statusDescription,
                       "openai-realtime (fail-through: apple)")
    }

    // MARK: - Apple

    func testAppleProviderReturnsTheClosuresProductDirectly() throws {
        let apple = ScriptedVoiceBackend(name: "apple")
        var builds = 0

        let selection = try VoiceBackendFactory.select(provider: .apple) {
            builds += 1
            return apple
        }

        XCTAssertTrue(selection.backend === apple,
                      "the default path must not be wrapped in anything")
        XCTAssertEqual(selection.provider, .apple)
        XCTAssertNil(selection.statusDescription)
        XCTAssertEqual(builds, 1)
    }

    /// The Apple provider is the one path that must work with no credentials at all.
    func testAppleProviderIgnoresTheAPIKeyEntirely() throws {
        let selection = try VoiceBackendFactory.select(provider: .apple, openAIAPIKey: nil) {
            ScriptedVoiceBackend(name: "apple")
        }
        XCTAssertEqual(selection.provider, .apple)
    }

    // MARK: - Missing credentials

    func testRealtimeWithoutAnAPIKeyThrowsAtStartup() {
        let spy = RealtimeSpy()
        var appleBuilds = 0

        for key in [nil, "", "   \n"] as [String?] {
            XCTAssertThrowsError(
                try select(.openaiRealtime, key: key, spy: spy,
                           onAppleBuild: { appleBuilds += 1 })
            ) { error in
                XCTAssertEqual(error as? VoiceBackendConfigurationError, .missingOpenAIAPIKey)
            }
        }

        XCTAssertEqual(
            VoiceBackendConfigurationError.missingOpenAIAPIKey.localizedDescription,
            "OpenAI Realtime voice requires OPENAI_API_KEY in the TapQ process environment."
        )
        XCTAssertEqual(appleBuilds, 0,
                       "a doomed startup must not open a recognizer on the way out")
        XCTAssertEqual(spy.apiKeys, [], "no session is built for a request that cannot run")
    }

    func testASurroundingWhitespaceKeyIsTrimmedRatherThanRejected() throws {
        let spy = RealtimeSpy()
        _ = try select(.openaiRealtime, key: "  sk-live-key\n", spy: spy)
        XCTAssertEqual(spy.apiKeys, ["sk-live-key"])
    }

    // MARK: - Composition

    func testRealtimeComposesFailThroughOverTheAppleBackend() throws {
        let spy = RealtimeSpy()
        let apple = ScriptedVoiceBackend(name: "apple")

        let selection = try select(.openaiRealtime, key: "sk-key", spy: spy, apple: apple)

        XCTAssertTrue(selection.backend is FailThroughVoiceBackend)
        XCTAssertEqual(selection.provider, .openaiRealtime)
        XCTAssertEqual(selection.statusDescription, "openai-realtime (fail-through: apple)")
        XCTAssertEqual(spy.apiKeys.count, 1)
        XCTAssertEqual(apple.calls, [], "composition alone must not open the microphone")
    }

    func testTheDiagnosticSinkReachesTheComposedBackends() async throws {
        let sink = RecordingSink()
        let spy = RealtimeSpy()

        let selection = try VoiceBackendFactory.select(
            provider: .openaiRealtime,
            openAIAPIKey: "sk-key",
            diagnosticSink: sink,
            makeAppleBackend: { ScriptedVoiceBackend(name: "apple") },
            makeRealtimeBackend: { key, sink in try spy.make(apiKey: key, sink: sink) }
        )
        XCTAssertTrue(spy.sinks.first as? RecordingSink === sink,
                      "the realtime session must log through the host's sink")

        try await selection.backend.open { _ in }
        selection.backend.close()

        // Only `FailThroughVoiceBackend` records these, so the wrapper got the sink too.
        XCTAssertEqual(sink.names, ["primary.opened", "session.closed"])
    }

    /// The composition is only worth anything if the fallback is actually reachable, so the
    /// factory's product is driven through a primary failure rather than merely inspected.
    func testTheComposedFallbackIsTheAppleBackend() async throws {
        let spy = RealtimeSpy()
        let apple = ScriptedVoiceBackend(name: "apple")
        spy.backend.openFailure = .network("no route to host")

        let selection = try select(.openaiRealtime, key: "sk-key", spy: spy, apple: apple)
        var received: [VoiceBackendEvent] = []
        try await selection.backend.open { received.append($0) }
        selection.backend.beginUserTurn()
        apple.emit(.transcriptFinal("yes"))

        XCTAssertEqual(apple.calls, [.open, .beginUserTurn])
        XCTAssertEqual(received, [.transcriptFinal("yes")])
    }

    func testAHealthyRealtimeSessionLeavesTheAppleFallbackInert() async throws {
        let spy = RealtimeSpy()
        let apple = ScriptedVoiceBackend(name: "apple")

        let selection = try select(.openaiRealtime, key: "sk-key", spy: spy, apple: apple)
        try await selection.backend.open { _ in }
        selection.backend.beginUserTurn()
        spy.backend.emit(.transcriptPartial("yes"))
        selection.backend.endUserTurn()
        selection.backend.close()

        XCTAssertEqual(spy.backend.calls,
                       [.open, .beginUserTurn, .endUserTurn, .close])
        XCTAssertEqual(apple.calls, [],
                       "a working cloud session must cost the on-device stack nothing")
    }

    #if canImport(Darwin)
    /// The one test that takes the real construction path. It proves the live branch
    /// compiles and composes; it opens nothing, because nothing in this file calls `open`
    /// on it and the transport connects no earlier than that.
    func testTheLiveRealtimePathComposesWithoutTouchingTheNetwork() throws {
        let apple = ScriptedVoiceBackend(name: "apple")
        let selection = try VoiceBackendFactory.select(
            provider: .openaiRealtime,
            openAIAPIKey: "sk-key"
        ) { apple }

        XCTAssertTrue(selection.backend is FailThroughVoiceBackend)
        XCTAssertEqual(apple.calls, [])
    }
    #endif

    // MARK: - Helpers

    @discardableResult
    private func select(
        _ provider: VoiceBackendProvider,
        key: String?,
        spy: RealtimeSpy,
        apple: ScriptedVoiceBackend? = nil,
        onAppleBuild: () -> Void = {}
    ) throws -> VoiceBackendSelection {
        let fallback = apple ?? ScriptedVoiceBackend(name: "apple")
        return try VoiceBackendFactory.select(
            provider: provider,
            openAIAPIKey: key,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            makeAppleBackend: {
                onAppleBuild()
                return fallback
            },
            makeRealtimeBackend: { apiKey, sink in try spy.make(apiKey: apiKey, sink: sink) }
        )
    }
}
