// swift-tools-version: 6.0
// The code the Mac app (../macos) and the iPhone and iPad app (../ios) share:
// the wire protocol and the platform-neutral client of `tabd`. Both depend on
// this package by path. See AGENTS.md for the rules.
import PackageDescription

let swift5 = [SwiftSetting.swiftLanguageMode(.v5)]

let package = Package(
    name: "TabShared",
    platforms: [.macOS(.v14), .iOS("27.0")],
    products: [
        .library(name: "TabProtocol", targets: ["TabProtocol"]),
        .library(name: "TabCommon", targets: ["TabCommon"]),
        .library(name: "TabConnection", targets: ["TabConnection"]),
    ],
    targets: [
        // Messages, framing, screen rows and their binary codec. No dependencies.
        .target(name: "TabProtocol", swiftSettings: swift5),

        // Release versions, loggers, terminal themes and the tab reducer.
        // Foundation only; TabCore re-exports it on the Mac.
        .target(
            name: "TabCommon",
            dependencies: ["TabProtocol"],
            resources: [.copy("Resources/Themes")],
            swiftSettings: swift5
        ),

        // A connection to a server over any byte stream: requests, replies,
        // screen grids, reconnects and tunnels. No sockets, processes or UI;
        // each app brings its own transport. TabClient re-exports it on the Mac.
        .target(name: "TabConnection", dependencies: ["TabCommon", "TabProtocol"], swiftSettings: swift5),

        .testTarget(name: "TabProtocolTests", dependencies: ["TabProtocol"], exclude: ["Fixtures"], swiftSettings: swift5),
        .testTarget(name: "TabCommonTests", dependencies: ["TabCommon", "TabProtocol"], swiftSettings: swift5),
        .testTarget(name: "TabConnectionTests", dependencies: ["TabConnection", "TabProtocol"], swiftSettings: swift5),
    ]
)
