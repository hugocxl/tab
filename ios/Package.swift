// swift-tools-version:6.0
// tabios: Tab for iPhone and iPad. See AGENTS.md for the layout and rules.
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5), .unsafeFlags(["-warnings-as-errors"])]

let tabProtocol = Target.Dependency.product(name: "TabProtocol", package: "shared")
let tabCommon = Target.Dependency.product(name: "TabCommon", package: "shared")
let tabConnection = Target.Dependency.product(name: "TabConnection", package: "shared")

let package = Package(
    name: "TabKit",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "TabMobileUI", targets: ["TabMobileUI"]),
    ],
    dependencies: [
        // The protocol and client shared with the Mac app.
        .package(path: "../shared"),
        .package(url: "https://github.com/hugocxl/stack.git", from: "0.1.4"),
    ],
    targets: [
        // Connections, pairing, tabs, terminals and agent chats, without UIKit.
        .target(name: "TabMobileKit", dependencies: [tabProtocol, tabCommon, tabConnection], swiftSettings: swift5),
        // The UIKit app: tab list, terminal and agent panes, pairing.
        .target(name: "TabMobileUI", dependencies: ["TabMobileKit", tabProtocol, tabCommon, tabConnection,
                                                     .product(name: "Icons", package: "stack")], swiftSettings: swift5),
        .testTarget(name: "TabMobileKitTests", dependencies: ["TabMobileKit"], swiftSettings: swift5),
        .testTarget(name: "TabMobileUITests", dependencies: ["TabMobileUI"], swiftSettings: swift5),
    ]
)
