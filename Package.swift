// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

var products: [Product] = [
    .library(name: "TapQContracts", targets: ["TapQContracts"]),
    .library(name: "TapQDetectionBaseline", targets: ["TapQDetectionBaseline"]),
    .library(name: "TapQInteractionBaseline", targets: ["TapQInteractionBaseline"]),
    .library(name: "TapQContextBaseline", targets: ["TapQContextBaseline"]),
    .library(name: "TapQWireProtocol", targets: ["TapQWireProtocol"]),
    .library(name: "TapQBrokerRuntime", targets: ["TapQBrokerRuntime"]),
    .library(name: "TapQPOSIXBridgeClient", targets: ["TapQPOSIXBridgeClient"]),
    .library(name: "TapQClaudeAdapter", targets: ["TapQClaudeAdapter"]),
    .library(name: "TapQCodexAdapter", targets: ["TapQCodexAdapter"]),
    .library(name: "TapQCursorAdapter", targets: ["TapQCursorAdapter"]),
    .library(name: "TapQOpenCodeAdapter", targets: ["TapQOpenCodeAdapter"]),
    .library(name: "TapQVoiceBackends", targets: ["TapQVoiceBackends"]),
    .executable(name: "tapq", targets: ["tapq"]),
    .executable(name: "tapq-hook", targets: ["tapq-hook"]),
    .executable(name: "tapq-codex-hook", targets: ["tapq-codex-hook"]),
    .executable(name: "tapq-cursor-hook", targets: ["tapq-cursor-hook"]),
    .executable(name: "tapq-opencode-hook", targets: ["tapq-opencode-hook"]),
]

var targets: [Target] = [
    .target(name: "TapQContracts", swiftSettings: swiftSettings),
    .target(
        name: "TapQDetectionBaseline",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQInteractionBaseline",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQContextBaseline",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQWireProtocol",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQPOSIXBridgeClient",
        dependencies: [],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQPOSIXSupport",
        dependencies: [],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQBrokerRuntime",
        dependencies: ["TapQContracts", "TapQWireProtocol"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQClaudeAdapter",
        dependencies: ["TapQContracts", "TapQPOSIXSupport", "TapQWireProtocol"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQCodexAdapter",
        dependencies: ["TapQContracts", "TapQPOSIXSupport", "TapQWireProtocol"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQCursorAdapter",
        dependencies: ["TapQContracts", "TapQPOSIXSupport", "TapQWireProtocol"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQOpenCodeAdapter",
        dependencies: ["TapQContracts", "TapQPOSIXSupport", "TapQWireProtocol"],
        swiftSettings: swiftSettings
    ),
    // Portable: the OpenAI Realtime adapter reaches the network only through an injected
    // transport seam, so the target itself imports nothing beyond Foundation and contracts.
    .target(
        name: "TapQVoiceBackends",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQCLI",
        dependencies: [
            "TapQClaudeAdapter",
            "TapQCodexAdapter",
            "TapQContextBaseline",
            "TapQContracts",
            "TapQCursorAdapter",
            "TapQDetectionBaseline",
            // Conversation memory composes the interaction layer's wait registry with the
            // context layer's event store. The composition belongs here, where the runtime
            // is assembled, rather than pushing a dependency edge between two baselines
            // that are deliberately independent of each other.
            "TapQInteractionBaseline",
            "TapQOpenCodeAdapter",
            "TapQPOSIXSupport",
            "TapQVoiceBackends",
            "TapQWireProtocol",
        ],
        swiftSettings: swiftSettings
    ),
    .executableTarget(
        name: "tapq-hook",
        dependencies: ["TapQClaudeAdapter", "TapQPOSIXBridgeClient", "TapQWireProtocol"],
        path: "Executables/tapq-hook",
        swiftSettings: swiftSettings
    ),
    .executableTarget(
        name: "tapq-codex-hook",
        dependencies: ["TapQCodexAdapter", "TapQPOSIXBridgeClient", "TapQWireProtocol"],
        path: "Executables/tapq-codex-hook",
        swiftSettings: swiftSettings
    ),
    .executableTarget(
        name: "tapq-cursor-hook",
        dependencies: ["TapQCursorAdapter", "TapQPOSIXBridgeClient", "TapQWireProtocol"],
        path: "Executables/tapq-cursor-hook",
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQContractsTests",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQDetectionBaselineTests",
        dependencies: ["TapQContracts", "TapQDetectionBaseline"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQInteractionBaselineTests",
        dependencies: ["TapQContracts", "TapQInteractionBaseline"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQContextBaselineTests",
        dependencies: ["TapQContracts", "TapQContextBaseline"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQWireProtocolTests",
        dependencies: ["TapQContracts", "TapQWireProtocol"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQPOSIXBridgeClientTests",
        dependencies: ["TapQPOSIXBridgeClient", "TapQWireProtocol"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQBrokerRuntimeTests",
        dependencies: [
            "TapQBrokerRuntime",
            "TapQContracts",
            "TapQPOSIXBridgeClient",
            "TapQWireProtocol",
        ],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQClaudeAdapterTests",
        dependencies: [
            "TapQClaudeAdapter",
            "TapQContracts",
            "TapQPOSIXSupport",
            "TapQWireProtocol",
        ],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQCodexAdapterTests",
        dependencies: [
            "TapQCodexAdapter",
            "TapQContracts",
            "TapQPOSIXSupport",
            "TapQWireProtocol",
        ],
        swiftSettings: swiftSettings
    ),
    .executableTarget(
        name: "tapq-opencode-hook",
        dependencies: ["TapQOpenCodeAdapter", "TapQPOSIXBridgeClient", "TapQWireProtocol"],
        path: "Executables/tapq-opencode-hook",
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQOpenCodeAdapterTests",
        dependencies: [
            "TapQContracts",
            "TapQOpenCodeAdapter",
            "TapQPOSIXSupport",
            "TapQWireProtocol",
        ],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQOpenCodeProcessTests",
        dependencies: [
            "TapQBrokerRuntime",
            "TapQContracts",
            "TapQWireProtocol",
        ],
        resources: [.copy("Fixtures")],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQCursorAdapterTests",
        dependencies: [
            "TapQContracts",
            "TapQCursorAdapter",
            "TapQPOSIXSupport",
            "TapQWireProtocol",
        ],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQCodexProcessTests",
        dependencies: [
            "TapQBrokerRuntime",
            "TapQContracts",
            "TapQWireProtocol",
        ],
        resources: [.copy("Fixtures")],
        swiftSettings: swiftSettings
    ),
    // `TapQInteractionBaseline` is a test-only dependency: the fail-through guarantee is
    // only meaningful one layer up, where a dying realtime session still has to resolve a
    // window through `VoiceBackendCommandProvider`, so that composition is proven here.
    .testTarget(
        name: "TapQVoiceBackendsTests",
        dependencies: ["TapQContracts", "TapQInteractionBaseline", "TapQVoiceBackends"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQCLITests",
        dependencies: [
            "TapQCLI", "TapQContextBaseline", "TapQDetectionBaseline", "TapQWireProtocol",
        ],
        swiftSettings: swiftSettings
    ),
    // End-to-end detection paths: simulated IMU traces through the real composed stack.
    // Portable on purpose — the whole path under test (detection, arbitration, decision,
    // wire) is portable, so a wiring regression must fail on Linux too.
    .testTarget(
        name: "TapQDetectionE2ETests",
        dependencies: [
            "TapQBrokerRuntime",
            "TapQCLI",
            "TapQContextBaseline",
            "TapQContracts",
            "TapQDetectionBaseline",
            "TapQInteractionBaseline",
            "TapQWireProtocol",
        ],
        swiftSettings: swiftSettings
    ),
]

// Apple acquisition and synthesis frameworks are intentionally absent from Linux's
// package graph. Portable targets above remain identical on macOS and Linux.
#if os(macOS)
products += [
    .library(name: "TapQAppleAdapters", targets: ["TapQAppleAdapters"]),
    .executable(name: "TapQMotionSpike", targets: ["TapQMotionSpike"]),
]

targets += [
    .target(
        name: "TapQAudioCaptureBridge",
        dependencies: [],
        linkerSettings: [
            .linkedFramework("AVFoundation"),
            .linkedFramework("Foundation"),
        ]
    ),
    .target(
        name: "TapQAppleAdapters",
        dependencies: [
            "TapQAudioCaptureBridge",
            "TapQContracts",
            "TapQDetectionBaseline",
            "TapQInteractionBaseline",
        ],
        swiftSettings: swiftSettings
    ),
    .executableTarget(
        name: "TapQMotionSpike",
        dependencies: ["TapQDetectionBaseline", "TapQAppleAdapters"],
        path: "Executables/TapQMotionSpike",
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQAudioCaptureBridgeTestSupport",
        dependencies: ["TapQAudioCaptureBridge"],
        path: "Tests/TapQAudioCaptureBridgeTestSupport",
        linkerSettings: [.linkedFramework("AVFoundation")]
    ),
    .testTarget(
        name: "TapQAppleAdaptersTests",
        dependencies: [
            "TapQAudioCaptureBridge",
            "TapQAudioCaptureBridgeTestSupport",
            "TapQContracts",
            "TapQDetectionBaseline",
            "TapQInteractionBaseline",
            "TapQAppleAdapters",
        ],
        swiftSettings: swiftSettings
    ),
]
#endif

var tapqExecutableDependencies: [Target.Dependency] = [
    "TapQBrokerRuntime",
    "TapQCLI",
    "TapQContextBaseline",
    "TapQContracts",
    "TapQDetectionBaseline",
    "TapQInteractionBaseline",
    "TapQVoiceBackends",
]

#if os(macOS)
tapqExecutableDependencies.append("TapQAppleAdapters")
#endif

targets.append(
    .executableTarget(
        name: "tapq",
        dependencies: tapqExecutableDependencies,
        path: "Executables/tapq",
        exclude: ["Info.plist", "TapQ.entitlements"],
        swiftSettings: swiftSettings,
        linkerSettings: [
            .unsafeFlags(
                [
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Executables/tapq/Info.plist",
                ],
                .when(platforms: [.macOS])
            ),
        ]
    )
)

let package = Package(
    name: "TapQOpen",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
