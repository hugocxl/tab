// swift-tools-version:6.0
// tabios: Tab for iPhone and iPad. See AGENTS.md for the layout and rules.
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5), .unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "TabKit",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "TabMobileUI", targets: ["TabMobileUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hugocxl/stack.git", from: "0.1.4"),
    ],
    targets: [
        // Synced from Tab by scripts/sync-tab.sh; never edited here.
        .target(name: "TabProtocol", path: "Vendor/TabProtocol", swiftSettings: swift5),
        .target(
            name: "TabShared",
            dependencies: ["TabProtocol"],
            path: "Vendor/TabShared",
            resources: [.copy("Tab/Resources/Themes")],
            swiftSettings: swift5
        ),
        // Connections, pairing, tabs, terminals and agent chats, without UIKit.
        .target(name: "TabMobileKit", dependencies: ["TabProtocol", "TabShared"], swiftSettings: swift5),
        // The UIKit app: tab list, terminal and agent panes, pairing.
        .target(name: "TabMobileUI", dependencies: ["TabMobileKit", "TabProtocol", "TabShared",
                                                     .product(name: "Icons", package: "stack")], swiftSettings: swift5),
        .testTarget(name: "TabMobileKitTests", dependencies: ["TabMobileKit"], swiftSettings: swift5),
        .testTarget(name: "TabMobileUITests", dependencies: ["TabMobileUI"], swiftSettings: swift5),
    ]
)
