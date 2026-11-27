import Foundation

// `Release`, `ReleaseChannel` and `ReleaseVersion` come from TabCommon, which the
// iOS app shares; the Mac-only parts below name the app's bundles and profiles.

extension Release {
    /// The Info.plist key naming a debug bundle's worktree.
    public static let devVariantKey = "TabDevVariant"

    /// The Git worktree a debug bundle was built from, such as `wt-3513`, so
    /// builds of several worktrees run side by side, each with its own name,
    /// profile and server. Nil for the main checkout and release builds.
    public static var devVariant: String? {
        guard isDebugBuild, let variant = Bundle.main.object(forInfoDictionaryKey: devVariantKey) as? String,
              !variant.isEmpty else { return nil }
        return variant
    }

    /// The app's bundle identifier for this kind of build.
    public static var bundleIdentifier: String {
        guard isDebugBuild else { return "com.hugocorta.tab" }
        return devVariant.map { "com.hugocorta.tab-dev.\($0)" } ?? "com.hugocorta.tab-dev"
    }

    /// The app's name for this kind of build.
    public static var appName: String { TabDirs.folderName(debug: isDebugBuild, variant: devVariant) }
}
