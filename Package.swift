// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// TapQ's module graph: speech in, addressing, one text model per decision, the coding agents
// as delegates, speech out.

var products: [Product] = [
    .library(name: "TapQContracts", targets: ["TapQContracts"]),
    .library(name: "TapQVoiceBackends", targets: ["TapQVoiceBackends"]),
    .library(name: "TapQKernel", targets: ["TapQKernel"]),
    .library(name: "TapQKernelClaude", targets: ["TapQKernelClaude"]),
    .library(name: "TapQKernelCodex", targets: ["TapQKernelCodex"]),
    .library(name: "TapQOpenAI", targets: ["TapQOpenAI"]),
    .library(name: "TapQVoiceIO", targets: ["TapQVoiceIO"]),
    .executable(name: "tapq-kernel", targets: ["tapq-kernel"]),
]

var targets: [Target] = [
    .target(name: "TapQContracts", swiftSettings: swiftSettings),
    // POSIX process control: `LineChannel` and `ChildProcess` (posix_spawn in its own
    // process group, three pipes, line readers). Builds and tests on both legs.
    .target(
        name: "TapQPOSIXSupport",
        dependencies: [],
        swiftSettings: swiftSettings
    ),
    // Portable: the OpenAI Realtime adapter reaches the network only through an injected
    // transport seam, so the target itself imports nothing beyond Foundation and contracts.
    .target(
        name: "TapQVoiceBackends",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    // The loop kernel. Portable by construction: no Apple framework, no network, no
    // subprocess. Speech, text models and delegates are protocols, so the whole loop is
    // provable in the container.
    .target(
        name: "TapQKernel",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    // Claude Code as a stream-json delegate over a `LineChannel`.
    .target(
        name: "TapQKernelClaude",
        dependencies: ["TapQKernel", "TapQContracts", "TapQPOSIXSupport"],
        swiftSettings: swiftSettings
    ),
    // Codex as a JSON-RPC delegate over `codex app-server` and a `LineChannel`.
    .target(
        name: "TapQKernelCodex",
        dependencies: ["TapQKernel", "TapQPOSIXSupport", "TapQContracts"],
        swiftSettings: swiftSettings
    ),
    // The Responses API behind `HTTPSending`: the intent model and the reply summarizer.
    // The URLSession transport is `#if canImport(Darwin)`.
    .target(
        name: "TapQOpenAI",
        dependencies: ["TapQKernel", "TapQContracts"],
        swiftSettings: swiftSettings
    ),
    // `RealtimeSpeechInput` and `RealtimeSpeechOutput`: STT and TTS realtime sessions over
    // `AudioCapturing` and `VoiceResponseAudioPlaying`.
    .target(
        name: "TapQVoiceIO",
        dependencies: ["TapQKernel", "TapQVoiceBackends", "TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQContractsTests",
        dependencies: ["TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQVoiceBackendsTests",
        // TapQVoiceIO is here so its adapter tests can reuse ScriptedRealtimeServer.
        dependencies: ["TapQContracts", "TapQVoiceBackends", "TapQKernel", "TapQVoiceIO"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQKernelClaudeTests",
        dependencies: ["TapQKernelClaude", "TapQKernel", "TapQContracts", "TapQPOSIXSupport"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQKernelCodexTests",
        dependencies: ["TapQKernelCodex", "TapQKernel", "TapQPOSIXSupport", "TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQOpenAITests",
        dependencies: ["TapQOpenAI", "TapQKernel", "TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQVoiceIOTests",
        dependencies: ["TapQVoiceIO", "TapQKernel", "TapQVoiceBackends", "TapQContracts"],
        swiftSettings: swiftSettings
    ),
    // `ChildProcess` against `/bin/sh` fakes: the one portable suite that spawns.
    .testTarget(
        name: "TapQPOSIXSupportTests",
        dependencies: ["TapQPOSIXSupport"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "TapQKernelTests",
        dependencies: ["TapQContracts", "TapQKernel"],
        swiftSettings: swiftSettings
    ),
]

// Apple acquisition and synthesis frameworks are intentionally absent from Linux's
// package graph. Portable targets above remain identical on macOS and Linux.
#if os(macOS)
products += [
    .library(name: "TapQAudioIO", targets: ["TapQAudioIO"]),
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
    // The microphone and the speaker: capture, conversion and playback. Speech-to-text and
    // text-to-speech happen at the service; this target only moves PCM. No detection, no
    // recognition.
    .target(
        name: "TapQAudioIO",
        dependencies: ["TapQAudioCaptureBridge", "TapQContracts"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "TapQAudioCaptureBridgeTestSupport",
        dependencies: ["TapQAudioCaptureBridge"],
        path: "Tests/TapQAudioCaptureBridgeTestSupport",
        linkerSettings: [.linkedFramework("AVFoundation")]
    ),
    .testTarget(
        name: "TapQAudioIOTests",
        dependencies: [
            "TapQAudioCaptureBridge",
            "TapQAudioCaptureBridgeTestSupport",
            "TapQAudioIO",
            "TapQContracts",
        ],
        swiftSettings: swiftSettings
    ),
]
#endif

// `tapq-kernel`: portable deps here; the audio adapters join on macOS below.
var kernelExecutableDependencies: [Target.Dependency] = [
    "TapQKernel", "TapQKernelClaude", "TapQKernelCodex", "TapQOpenAI", "TapQVoiceIO",
    "TapQVoiceBackends", "TapQContracts", "TapQPOSIXSupport",
]

#if os(macOS)
kernelExecutableDependencies.append("TapQAudioIO")
#endif

targets.append(
    // The loop kernel's own executable: command line, startup checks, composition, status
    // writer. Nothing else.
    .executableTarget(
        name: "tapq-kernel",
        dependencies: kernelExecutableDependencies,
        path: "Executables/tapq-kernel",
        exclude: ["Info.plist"],
        swiftSettings: swiftSettings,
        linkerSettings: [
            .unsafeFlags(
                [
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Executables/tapq-kernel/Info.plist",
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
