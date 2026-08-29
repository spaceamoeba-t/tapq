import XCTest
@testable import TapQVoiceBackends
import TapQContracts

/// What the factory promises, in the order the promises matter:
///
/// 1. The default provider is a pass-through — no wrapper, no policy, no cost.
/// 2. An explicitly requested cloud backend with no credentials fails at startup rather
///    than quietly serving the on-device one.
/// 3. The cloud path composes *nothing* underneath itself. That is the whole of the
///    no-cross-backend-degradation policy as the factory can state it: a run that asked
///    for one backend gets one backend, and the on-device recognizer is not built, not
///    opened, and not reachable.
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
    func testProviderRawValuesAreTheFlagSpellings() async {
        XCTAssertEqual(VoiceBackendProvider.allCases.map(\.rawValue),
                       ["apple", "openai-realtime"])
        XCTAssertEqual(VoiceBackendProvider(rawValue: "openai-realtime"), .openaiRealtime)
        XCTAssertNil(VoiceBackendProvider(rawValue: "openai_realtime"))
    }

    /// The ready line names the pipe and nothing else. It used to carry a
    /// "(fail-through: apple)" suffix, and dropping it is not cosmetic: an operator reading
    /// that line was being told a second backend would catch a failure, and none will.
    func testOnlyTheNonDefaultProviderReportsAStatusLine() async {
        XCTAssertNil(VoiceBackendProvider.apple.statusDescription)
        XCTAssertEqual(VoiceBackendProvider.openaiRealtime.statusDescription,
                       "openai-realtime")
    }

    // MARK: - Apple

    func testAppleProviderReturnsTheClosuresProductDirectly() async throws {
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
    func testAppleProviderIgnoresTheAPIKeyEntirely() async throws {
        let selection = try VoiceBackendFactory.select(provider: .apple, openAIAPIKey: nil) {
            ScriptedVoiceBackend(name: "apple")
        }
        XCTAssertEqual(selection.provider, .apple)
    }

    // MARK: - Missing credentials

    func testRealtimeWithoutAnAPIKeyThrowsAtStartup() async {
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

    func testASurroundingWhitespaceKeyIsTrimmedRatherThanRejected() async throws {
        let spy = RealtimeSpy()
        _ = try select(.openaiRealtime, key: "  sk-live-key\n", spy: spy)
        XCTAssertEqual(spy.apiKeys, ["sk-live-key"])
    }

    // MARK: - Composition

    func testRealtimeReturnsTheRealtimeBackendItself() async throws {
        let spy = RealtimeSpy()
        let apple = ScriptedVoiceBackend(name: "apple")

        let selection = try select(.openaiRealtime, key: "sk-key", spy: spy, apple: apple)

        XCTAssertTrue(selection.backend === spy.backend,
                      "the named backend is the pipe, unmediated")
        XCTAssertEqual(selection.provider, .openaiRealtime)
        XCTAssertEqual(selection.statusDescription, "openai-realtime")
        XCTAssertEqual(spy.apiKeys.count, 1)
        XCTAssertEqual(apple.calls, [], "composition alone must not open the microphone")
    }

    /// The negative that carries the policy: choosing the cloud path must not so much as
    /// *build* an on-device recognizer. A fallback that exists is a fallback something can
    /// eventually reach, and the whole point is that nothing can.
    func testTheCloudPathNeverBuildsTheAppleBackend() async throws {
        let spy = RealtimeSpy()
        var appleBuilds = 0

        let selection = try select(.openaiRealtime, key: "sk-key", spy: spy,
                                   onAppleBuild: { appleBuilds += 1 })
        // Drive a failure through it: under the old composition this is exactly the moment
        // the Apple stack was constructed and opened underneath.
        spy.backend.openFailure = .network("no route to host")
        do {
            try await selection.backend.open { _ in }
            XCTFail("a failed open must surface rather than land on a second backend")
        } catch {
            XCTAssertEqual(error as? VoiceBackendFailure, .network("no route to host"))
        }

        XCTAssertEqual(appleBuilds, 0)
    }

    func testTheDiagnosticSinkReachesTheSelectedBackend() async throws {
        let sink = RecordingSink()
        let spy = RealtimeSpy()

        _ = try VoiceBackendFactory.select(
            provider: .openaiRealtime,
            openAIAPIKey: "sk-key",
            diagnosticSink: sink,
            makeAppleBackend: { ScriptedVoiceBackend(name: "apple") },
            makeRealtimeBackend: { key, sink in try spy.make(apiKey: key, sink: sink) }
        )
        XCTAssertTrue(spy.sinks.first as? RecordingSink === sink,
                      "the realtime session must log through the host's sink")
        XCTAssertEqual(sink.names, [],
                       "the factory itself has nothing to say; construction is inert")
    }

    func testAHealthyRealtimeSessionIsDrivenDirectly() async throws {
        let spy = RealtimeSpy()
        let apple = ScriptedVoiceBackend(name: "apple")

        let selection = try select(.openaiRealtime, key: "sk-key", spy: spy, apple: apple)
        try await selection.backend.open { _ in }
        selection.backend.beginUserTurn()
        spy.backend.emit(.transcriptPartial("yes"))
        selection.backend.endUserTurn(expectingResponse: true)
        selection.backend.close()

        XCTAssertEqual(spy.backend.calls,
                       [.open, .beginUserTurn, .endUserTurn, .close])
        XCTAssertEqual(apple.calls, [],
                       "there is no on-device stack in this composition at all")
    }

    #if canImport(Darwin)
    /// The one test that takes the real construction path. It proves the live branch
    /// compiles and composes; it opens nothing, because nothing in this file calls `open`
    /// on it and the transport connects no earlier than that.
    func testTheLiveRealtimePathComposesWithoutTouchingTheNetwork() async throws {
        let apple = ScriptedVoiceBackend(name: "apple")
        let selection = try VoiceBackendFactory.select(
            provider: .openaiRealtime,
            openAIAPIKey: "sk-key"
        ) { apple }

        XCTAssertTrue(selection.backend is OpenAIRealtimeVoiceBackend)
        XCTAssertEqual(apple.calls, [])
    }
    #endif

    // MARK: - Decorator

    /// The decorator wraps only the realtime primary, never the Apple path.
    func testDecoratorIsAppliedToRealtimePrimaryOnly() async throws {
        let spy = RealtimeSpy()
        var decorated: (any VoiceBackend)?
        let selection = try VoiceBackendFactory.select(
            provider: .openaiRealtime,
            openAIAPIKey: "sk-key",
            decorateRealtimePrimary: { primary in
                decorated = primary
                return ScriptedVoiceBackend(name: "decorated")
            },
            diagnosticSink: NoOpTapQDiagnosticSink(),
            makeAppleBackend: { ScriptedVoiceBackend(name: "apple") },
            makeRealtimeBackend: { apiKey, sink in try spy.make(apiKey: apiKey, sink: sink) }
        )

        XCTAssertTrue(decorated === spy.backend,
                      "the decorator receives the raw realtime backend")
        XCTAssertEqual((selection.backend as? ScriptedVoiceBackend)?.name, "decorated",
                       "the decorator's product is the selection, with nothing above it")
    }

    func testDecoratorIsNotInvokedForAppleProvider() async throws {
        var decoratorCalled = false
        let selection = try VoiceBackendFactory.select(
            provider: .apple,
            openAIAPIKey: nil,
            decorateRealtimePrimary: { backend in
                decoratorCalled = true
                return backend
            },
            diagnosticSink: NoOpTapQDiagnosticSink(),
            makeAppleBackend: { ScriptedVoiceBackend(name: "apple") },
            makeRealtimeBackend: { _, _ in ScriptedVoiceBackend(name: "realtime") }
        )

        XCTAssertFalse(decoratorCalled,
                       "the Apple path must not invoke the realtime decorator")
        XCTAssertTrue(selection.backend is ScriptedVoiceBackend)
        XCTAssertEqual(selection.provider, .apple)
    }

    func testNilDecoratorLeavesThePrimaryUnwrapped() async throws {
        let spy = RealtimeSpy()
        let selection = try VoiceBackendFactory.select(
            provider: .openaiRealtime,
            openAIAPIKey: "sk-key",
            decorateRealtimePrimary: nil,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            makeAppleBackend: { ScriptedVoiceBackend(name: "apple") },
            makeRealtimeBackend: { apiKey, sink in try spy.make(apiKey: apiKey, sink: sink) }
        )

        XCTAssertTrue(selection.backend === spy.backend,
                      "with no decorator the raw backend is what comes back")
    }

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
