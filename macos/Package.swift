// swift-tools-version: 6.0
import PackageDescription

// Tab is a native macOS terminal workspace. See AGENTS.md for the
// module boundaries; keep this dependency graph in sync with it.
let swift5 = [SwiftSetting.swiftLanguageMode(.v5)]

// From ../shared, the package the iPhone and iPad app shares.
let tabProtocol = Target.Dependency.product(name: "TabProtocol", package: "shared")
let tabCommon = Target.Dependency.product(name: "TabCommon", package: "shared")
let tabConnection = Target.Dependency.product(name: "TabConnection", package: "shared")

let package = Package(
    name: "Tab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TabDesktop", targets: ["TabDesktop"]),
        .executable(name: "tabd", targets: ["tabd"]),
        .executable(name: "tab", targets: ["tab"]),
    ],
    dependencies: [
        .package(path: "../shared"),
        .package(url: "https://github.com/hugocxl/stack.git", from: "0.1.4"),
    ],
    targets: [
        // Ghostty's VT library, built by scripts/build-ghostty.sh.
        .binaryTarget(name: "GhosttyVT", path: "vendor/GhosttyVT.xcframework"),

        // App basics: folders, shortcut catalog, settings model, split layouts,
        // app state, fuzzy matching. Re-exports TabProtocol and TabCommon
        // (releases, loggers, themes, the tab reducer).
        .target(name: "TabCore", dependencies: [tabProtocol, tabCommon], swiftSettings: swift5),

        // The Ghostty terminal and the PTY, used only by the server.
        .target(
            name: "TabTerminal",
            dependencies: ["GhosttyVT", tabProtocol],
            swiftSettings: swift5
        ),

        // iOS simulators and Android emulators: listing, controlling, their
        // screens and input, and the video codec that streams screens. No AppKit.
        .target(name: "TabSimulators", dependencies: ["TabCore", tabProtocol], swiftSettings: swift5),

        // The server: projects, sessions, history, Git, files, search, agent
        // detection, shell integration, mobile access, tunnels and simulators.
        .target(
            name: "TabServer",
            dependencies: ["TabCore", "TabSimulators", tabProtocol, "TabTerminal"],
            resources: [.copy("Resources/Detection"), .copy("Resources/Shell")],
            swiftSettings: swift5
        ),
        .executableTarget(name: "tabd", dependencies: ["TabServer", "TabCore", tabProtocol], swiftSettings: swift5),

        // Connects to a server, starting a local one if needed, or over SSH.
        // Re-exports TabConnection, the client the iOS app shares.
        .target(name: "TabClient", dependencies: ["TabCore", tabProtocol, tabConnection], swiftSettings: swift5),

        // The `tab` command line tool.
        .executableTarget(
            name: "tab",
            dependencies: ["TabClient", "TabCore", tabProtocol],
            swiftSettings: swift5
        ),

        // The desktop app (AppKit, with SwiftUI for Settings forms).
        .target(
            name: "TabApp",
            dependencies: ["TabClient", "TabCore", "TabSimulators", tabProtocol,
                           .product(name: "Icons", package: "stack")],
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "TabDesktop",
            dependencies: ["TabApp"],
            swiftSettings: swift5,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export_dynamic"])]
        ),

        // Optional lazy-loaded plugins (never linked into TabDesktop; built as
        // loadable .bundle archives by scripts/build-plugins.sh).
        .target(
            name: "TabExplorerPlugin",
            dependencies: ["TabApp", "TabCore", tabProtocol],
            swiftSettings: swift5
        ),
        .target(
            name: "TabDiffPlugin",
            dependencies: ["TabApp", "TabCore", tabProtocol],
            swiftSettings: swift5
        ),
        .target(
            name: "TabUsagePlugin",
            dependencies: ["TabApp", "TabCore", tabProtocol],
            swiftSettings: swift5
        ),
        .target(
            name: "TabGitGraphPlugin",
            dependencies: ["TabApp", "TabCore", tabProtocol],
            swiftSettings: swift5
        ),
        .target(
            name: "TabQuickShotPlugin",
            dependencies: ["TabApp", "TabCore"],
            swiftSettings: swift5
        ),

        .testTarget(name: "TabCoreTests", dependencies: ["TabCore"], swiftSettings: swift5),
        .testTarget(name: "TabSimulatorsTests", dependencies: ["TabSimulators", tabProtocol], swiftSettings: swift5),
        .testTarget(name: "TabTerminalTests", dependencies: ["TabTerminal"], swiftSettings: swift5),
        .testTarget(name: "TabServerTests", dependencies: ["TabServer"], swiftSettings: swift5),
        .testTarget(name: "TabClientTests", dependencies: ["TabClient", "TabServer"], swiftSettings: swift5),
        .testTarget(name: "TabAppTests", dependencies: ["TabApp", "TabServer", "TabExplorerPlugin", "TabDiffPlugin", "TabUsagePlugin",
                                                       "TabGitGraphPlugin", "TabQuickShotPlugin"], swiftSettings: swift5),
    ]
)
