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
    .executable(name: "tapq", targets: ["tapq"]),
    .executable(name: "tapq-hook", targets: ["tapq-hook"]),
    .executable(name: "tapq-codex-hook", targets: ["tapq-codex-hook"]),
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
        name: "TapQCLI",
        dependencies: [
            "TapQClaudeAdapter",
            "TapQCodexAdapter",
            "TapQContracts",
            "TapQDetectionBaseline",
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
    .testTarget(
        name: "TapQCLITests",
        dependencies: ["TapQCLI", "TapQDetectionBaseline", "TapQWireProtocol"],
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
        name: "TapQAppleAdapters",
        dependencies: ["TapQContracts", "TapQDetectionBaseline", "TapQInteractionBaseline"],
        swiftSettings: swiftSettings
    ),
    .executableTarget(
        name: "TapQMotionSpike",
        dependencies: ["TapQDetectionBaseline", "TapQAppleAdapters"],
        path: "Executables/TapQMotionSpike",
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQAppleAdaptersTests",
        dependencies: [
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
