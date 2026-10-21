// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HugeDisplay",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "HugeDisplay", targets: ["HugeDisplay"]),
    ],
    targets: [
        .target(
            name: "HugeDisplayCore",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ColorSync"),
            ]
        ),
        .executableTarget(
            name: "HugeDisplay",
            dependencies: ["HugeDisplayCore"]
        ),
        .testTarget(
            name: "HugeDisplayCoreTests",
            dependencies: ["HugeDisplayCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
