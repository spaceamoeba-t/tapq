// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// The example tracks the checkout it lives in, so a change to the SDK is visible here
// without a tag. A real consumer uses the `url:` + version form shown in README.md.
let package = Package(
    name: "GestureBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Named explicitly: the identity SwiftPM infers for a path dependency is the
        // checkout's directory name, which is not stable across clones.
        .package(name: "TapQOpen", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "GestureBar",
            dependencies: [
                .product(name: "TapQGestures", package: "TapQOpen")
            ],
            swiftSettings: swiftSettings,
            linkerSettings: [
                // Embeds the Info.plist in the binary as well as in the bundle the
                // packaging script assembles: TCC reads the usage description from the
                // running executable, which is not always the bundled copy.
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", "Info.plist",
                    ],
                    .when(platforms: [.macOS])
                ),
            ]
        )
    ]
)
