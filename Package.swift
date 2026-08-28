// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MyTerminal",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Ghostty terminal engine (libghostty) as a prebuilt XCFramework
        // + Swift wrapper with native views, Metal rendering, input handling.
        // NOTE: pinned minor range — libghostty's C API is not stable yet,
        // so upgrades must be deliberate (see docs/roadmap.md).
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.4.0")
    ],
    targets: [
        .executableTarget(
            name: "MyTerminal",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                // 485 iTerm2 color schemes (GhosttyThemeCatalog)
                .product(name: "GhosttyTheme", package: "libghostty-spm")
            ],
            path: "Sources/MyTerminal"
        ),
        .testTarget(
            name: "MyTerminalTests",
            dependencies: ["MyTerminal"],
            path: "Tests/MyTerminalTests"
        )
    ]
)
