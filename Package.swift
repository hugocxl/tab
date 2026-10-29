// swift-tools-version: 6.0
import PackageDescription

// Tab is a native macOS terminal workspace. See docs/ARCHITECTURE.md for the
// module boundaries; keep this dependency graph in sync with that document.
let swift5 = [SwiftSetting.swiftLanguageMode(.v5)]

let package = Package(
    name: "Tab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TabDesktop", targets: ["TabDesktop"]),
        .executable(name: "tabd", targets: ["tabd"]),
        .executable(name: "tab", targets: ["tab"]),
    ],
    targets: [
        // Ghostty's VT library, built by scripts/build-ghostty.sh.
        .binaryTarget(name: "GhosttyVT", path: "vendor/GhosttyVT.xcframework"),

        // Messages, framing, screen rows and their binary codec. No dependencies.
        .target(name: "TabProtocol", swiftSettings: swift5),

        // Shared app basics: folders, shortcut catalog, settings model, themes,
        // split layouts, app state, fuzzy matching. Re-exports TabProtocol's ids.
        .target(name: "TabCore", dependencies: ["TabProtocol"], resources: [.copy("Resources/Themes")], swiftSettings: swift5),

        // The Ghostty terminal and the PTY, used only by the server.
        .target(
            name: "TabTerminal",
            dependencies: ["GhosttyVT", "TabProtocol"],
            swiftSettings: swift5
        ),

        // The server: projects, sessions, history, Git, files, search, agent
        // detection, shell integration, mobile access.
        .target(
            name: "TabServer",
            dependencies: ["TabCore", "TabProtocol", "TabTerminal"],
            resources: [.copy("Resources/Detection"), .copy("Resources/Shell")],
            swiftSettings: swift5
        ),
        .executableTarget(name: "tabd", dependencies: ["TabServer"], swiftSettings: swift5),

        // Connects to a server, starting a local one if needed, or over SSH.
        .target(name: "TabClient", dependencies: ["TabCore", "TabProtocol"], swiftSettings: swift5),

        // The `tab` command line tool.
        .executableTarget(
            name: "tab",
            dependencies: ["TabClient", "TabCore", "TabProtocol"],
            swiftSettings: swift5
        ),

        // The desktop app (AppKit, with SwiftUI for Settings forms).
        .target(
            name: "TabApp",
            dependencies: ["TabClient", "TabCore", "TabProtocol"],
            resources: [.copy("Resources/Icons")],
            swiftSettings: swift5
        ),
        .executableTarget(name: "TabDesktop", dependencies: ["TabApp"], swiftSettings: swift5),

        .testTarget(name: "TabCoreTests", dependencies: ["TabCore"], swiftSettings: swift5),
        .testTarget(name: "TabProtocolTests", dependencies: ["TabProtocol"], exclude: ["Fixtures"], swiftSettings: swift5),
        .testTarget(name: "TabTerminalTests", dependencies: ["TabTerminal"], swiftSettings: swift5),
        .testTarget(name: "TabServerTests", dependencies: ["TabServer"], swiftSettings: swift5),
        .testTarget(name: "TabClientTests", dependencies: ["TabClient", "TabServer"], swiftSettings: swift5),
        .testTarget(name: "TabAppTests", dependencies: ["TabApp", "TabServer"], swiftSettings: swift5),
    ]
)
