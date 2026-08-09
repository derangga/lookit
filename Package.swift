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

        // The app layer: boundaries, transport, state. Imports Foundation and
        // AppKit freely — everything LookitCore may not.
        .target(
            name: "Lookit",
            dependencies: ["LookitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Assert-based self-check. Its dependency on LookitCore alone would
        // prove the core standalone; it also covers the boundary parsers, which
        // is why Lookit is a library rather than living inside the executable.
        .executableTarget(
            name: "lookit-check",
            dependencies: ["LookitCore", "Lookit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
