import AppKit
import TabCore
import WebKit

/// A browser profile: its own cookies, site data, logins and history.
public struct BrowserProfile: Codable, Equatable, Sendable {
    /// Empty for the Default profile; otherwise a lowercase UUID, which also
    /// names its `WKWebsiteDataStore`.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var isBuiltInDefault: Bool { id.isEmpty }
}

/// The browser profiles, kept in `browser/profiles.json` in the profile
/// folder, each with a folder `browser/<id>/` (`default` for the Default
/// profile) holding its history. The Default profile uses the app's default
/// website data store; every other profile has its own persistent store.
///
/// Settings calls the `SettingsHost`-shaped methods; panes ask for data
/// stores and histories here. Live panes register in `panes`, so deleting a
/// profile can move its panes to the default profile first.
@MainActor
public final class BrowserProfiles {
    public static let defaultName = "Default"

    /// `browser/` in the profile folder.
    public let root: URL
    /// Open browser panes, by tab ID.
    public let panes = BrowserPaneRegistry()
    /// The id of the profile new panes use (`BrowserSettings.defaultProfile`).
    public var defaultProfileId: String = ""
    /// Reports what a background job finished, such as an import.
    public var notify: ((String, _ isError: Bool) -> Void)?

    public private(set) var profiles: [BrowserProfile]
    private var histories: [String: BrowserHistoryStore] = [:]
    private var stores: [String: WKWebsiteDataStore] = [:]

    public init(root: URL) {
        self.root = root
        let saved = (try? Data(contentsOf: root.appendingPathComponent("profiles.json")))
            .flatMap { try? JSONDecoder().decode([BrowserProfile].self, from: $0) } ?? []
        profiles = [BrowserProfile(id: "", name: Self.defaultName)] + saved.filter { !$0.isBuiltInDefault }
    }

    /// The store under the app's profile folder: `<profile>/browser`.
    public convenience init(dirs: TabDirs) {
        self.init(root: dirs.root.appendingPathComponent("browser", isDirectory: true))
    }

    // MARK: Lookup

    /// The profile `wanted` names by id or name, or the default one for
    /// `nil` or empty text.
    public func resolve(_ wanted: String?) throws -> BrowserProfile {
        guard let wanted, !wanted.isEmpty else { return defaultProfile }
        if let profile = profiles.first(where: { $0.id == wanted.lowercased() }) { return profile }
        if let profile = profiles.first(where: { $0.name == wanted }) { return profile }
        if let profile = profiles.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return profile }
        throw BrowserScripts.Failure("no browser profile named '\(wanted)'")
    }

    /// A pane's saved profile, or the default when it is gone.
    public func profile(forSaved id: String?) -> BrowserProfile {
        guard let id, let profile = profiles.first(where: { $0.id == id }) else { return defaultProfile }
        return profile
    }

    public var defaultProfile: BrowserProfile {
        profiles.first { $0.id == defaultProfileId } ?? profiles[0]
    }

    /// Profiles as menus list them: the default first, then by name.
    public var ordered: [BrowserProfile] {
        let chosen = defaultProfile.id
        return profiles.sorted { lhs, rhs in
            if (lhs.id == chosen) != (rhs.id == chosen) { return lhs.id == chosen }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The website data store `profile` browses with.
    public func dataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
        if let store = stores[profile.id] { return store }
        let store: WKWebsiteDataStore
        if profile.isBuiltInDefault {
            store = .default()
        } else if let identifier = UUID(uuidString: profile.id) {
            store = WKWebsiteDataStore(forIdentifier: identifier)
        } else {
            store = .nonPersistent()
        }
        stores[profile.id] = store
        return store
    }

    /// The folder holding `profile`'s app-side files.
    public func folder(for profile: BrowserProfile) -> URL {
        root.appendingPathComponent(profile.isBuiltInDefault ? "default" : profile.id, isDirectory: true)
    }

    public func history(for profile: BrowserProfile) -> BrowserHistoryStore {
        if let history = histories[profile.id] { return history }
        let history = BrowserHistoryStore(file: folder(for: profile).appendingPathComponent("browser-history.json"))
        histories[profile.id] = history
        return history
    }

    /// Writes every profile's pending history, such as before quitting.
    public func saveHistories() {
        histories.values.forEach { $0.saveNow() }
    }

    // MARK: Changes

    @discardableResult
    public func add(named name: String) throws -> BrowserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = BrowserProfile(id: UUID().uuidString.lowercased(), name: trimmed.isEmpty ? "Profile" : trimmed)
        profiles.append(profile)
        try save()
        return profile
    }

    public func rename(_ id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserScripts.Failure("A profile needs a name") }
        guard let position = profiles.firstIndex(where: { $0.id == id }) else {
            throw BrowserScripts.Failure("no browser profile with ID \(id)")
        }
        profiles[position].name = trimmed
        try save()
    }

    /// Deletes a profile with its cookies, site data and history. Its open
    /// panes browse with the default profile from then on.
    public func delete(_ id: String) async throws {
        guard !id.isEmpty, id != defaultProfile.id else {
            throw BrowserScripts.Failure("The default profile can't be deleted")
        }
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw BrowserScripts.Failure("no browser profile with ID \(id)")
        }
        let fallback = defaultProfile
        for pane in panes.all where pane.profile.id == id {
            pane.switchProfile(to: fallback)
        }
        profiles.removeAll { $0.id == id }
        try save()
        histories[id] = nil
        stores[id] = nil
        try? FileManager.default.removeItem(at: folder(for: profile))
        guard let identifier = UUID(uuidString: id) else { return }
        try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }

    /// Signs the profile out of everything: its cookies, site data and
    /// history go.
    public func clearData(_ id: String) async throws {
        let profile = try resolve(id.isEmpty ? defaultProfile.id : id)
        history(for: profile).clear()
        let store = dataStore(for: profile)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles.filter { !$0.isBuiltInDefault })
        try data.write(to: root.appendingPathComponent("profiles.json"), options: .atomic)
    }

    // MARK: Settings

    /// Profiles as Settings lists them.
    public func browserProfiles() -> [BrowserProfileSummary] {
        ordered.map { BrowserProfileSummary(id: $0.id, name: $0.name) }
    }

    public func addBrowserProfile(named name: String) throws -> BrowserProfileSummary {
        let profile = try add(named: name)
        return BrowserProfileSummary(id: profile.id, name: profile.name)
    }

    public func renameBrowserProfile(_ id: String, to name: String) throws {
        try rename(id, to: name)
    }

    public func deleteBrowserProfile(_ id: String) async throws {
        try await delete(id)
    }

    public func clearBrowserProfileData(_ id: String) async throws {
        try await clearData(id)
        notify?("Cleared browsing data for “\(try resolve(id.isEmpty ? nil : id).name)”", false)
    }

    /// Browsers on this Mac whose history, bookmarks or cookies can be read.
    public func browserImportSources() -> [BrowserImportSource] {
        BrowserImport.detect().map { BrowserImportSource(name: $0.displayName, supportsCookies: $0.supportsCookies) }
    }

    /// Imports history and bookmarks, or with `cookies` the sign-ins, from
    /// another browser into the default profile.
    public func importBrowserData(from source: BrowserImportSource, cookies: Bool) async throws {
        guard let external = BrowserImport.detect().first(where: { $0.displayName == source.name }) else {
            throw BrowserScripts.Failure("That browser is no longer available")
        }
        let profile = defaultProfile
        if cookies {
            let read = try await Task.detached(priority: .userInitiated) { try BrowserImport.readCookies(external) }.value
            let store = dataStore(for: profile).httpCookieStore
            var written = 0
            for cookie in read.compactMap(\.httpCookie) {
                await store.setCookie(cookie)
                written += 1
            }
            notify?("Imported \(written) cookies from \(source.name) into “\(profile.name)”", false)
            return
        }
        let read = try await Task.detached(priority: .userInitiated) { try BrowserImport.readHistory(external) }.value
        let added = history(for: profile).merge(read.visits + read.bookmarks)
        history(for: profile).saveNow()
        notify?("Imported \(read.visits.count) visits and \(read.bookmarks.count) bookmarks from \(source.name) (\(added) new pages)", false)
    }
}

/// The open browser panes, by tab ID, held weakly so closed panes drop out.
@MainActor
public final class BrowserPaneRegistry {
    private final class Weak {
        weak var pane: BrowserPaneController?
        init(_ pane: BrowserPaneController) { self.pane = pane }
    }

    private var entries: [String: Weak] = [:]

    public init() {}

    public func register(_ pane: BrowserPaneController) {
        entries[pane.tabId] = Weak(pane)
    }

    public func unregister(_ tabId: String) {
        entries[tabId] = nil
    }

    public func pane(_ tabId: String) -> BrowserPaneController? {
        entries[tabId]?.pane
    }

    public var all: [BrowserPaneController] {
        entries = entries.filter { $0.value.pane != nil }
        return entries.values.compactMap(\.pane)
    }
}
