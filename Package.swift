// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "lookit",
    platforms: [.macOS(.v13)],
    targets: [
        // R = never. Imports nothing — not AppKit, not Foundation, not
        // CoreGraphics. The module boundary is what enforces invariant 5:
        // this target must stay liftable into a C++ OBS filter unchanged.
        .target(
            name: "LookitCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Assert-based self-check. Depends only on LookitCore, which is also
        // how we prove the core has no hidden dependencies.
        .executableTarget(
            name: "lookit-check",
            dependencies: ["LookitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
