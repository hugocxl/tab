import Foundation
import os

// The two TabCore symbols the synced client code uses. Not overwritten by
// scripts/sync-tab.sh, which only replaces Vendor/TabShared/Tab.

/// This build's version, sent to the server in `hello`.
public enum Release {
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0-dev"
    }
}

/// Loggers for the synced code.
public enum Log {
    public static let client = Logger(subsystem: "com.hugocorta.tabios", category: "client")
}
