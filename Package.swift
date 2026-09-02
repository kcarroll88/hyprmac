// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hyprmac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hyprmac", targets: ["hyprmac"]),
        .library(name: "HyprCore", targets: ["HyprCore"]),
    ],
    targets: [
        // Pure, platform-free: layout tree, config parsing, geometry. Fully unit tested.
        .target(name: "HyprCore", swiftSettings: [.swiftLanguageMode(.v5)]),

        // macOS glue: Accessibility API, displays, the window backend protocol.
        .target(name: "HyprKit", dependencies: ["HyprCore"], swiftSettings: [.swiftLanguageMode(.v5)]),

        // The app: canvas window, hotkey daemon, the manager that ties it together.
        .executableTarget(name: "hyprmac", dependencies: ["HyprCore", "HyprKit"], swiftSettings: [.swiftLanguageMode(.v5)]),

        .testTarget(name: "HyprCoreTests", dependencies: ["HyprCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
