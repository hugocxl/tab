import AppKit
import TabCore
import TabProtocol

/// A browser pane as `tab browser list` reports it.
public struct BrowserTab: Equatable, Sendable {
    /// The pane's ID, which `tab browser` commands name it by.
    public var tabId: String
    /// What the pane saves: its address and profile.
    public var state: BrowserPane
    /// Whether it is the pane shown in its project.
    public var active: Bool

    public init(tabId: String, state: BrowserPane, active: Bool) {
        self.tabId = tabId
        self.state = state
        self.active = active
    }
}

/// Whose network a browser pane loads pages from.
public enum BrowserNetwork: Equatable, Sendable {
    /// This Mac's.
    case local
    /// Another computer's server, through its tunnels.
    case remote(server: ServerId, name: String)

    var server: ServerId? {
        if case .remote(let server, _) = self { return server }
        return nil
    }
}

/// What browser panes and `BrowserAutomation` need from the app shell. The
/// shell owns panes, layouts and saving; the browser owns pages.
@MainActor
public protocol BrowserHost: AnyObject {
    var theme: AppTheme { get }
    /// The browser settings in effect.
    var browserSettings: BrowserSettings { get }
    var browserProfiles: BrowserProfiles { get }
    /// The network of the pane's tab: its server's.
    func browserNetwork(forTab tabId: String) -> BrowserNetwork
    /// Whether the server is connected now.
    func browserServerConnected(_ server: ServerId) -> Bool

    // MARK: From a pane

    /// A page opened a window: show `url` in a new browser pane next to
    /// `source`, with `profile` (a profile id).
    func openBrowserPane(url: String, profile: String, from source: BrowserPaneController)
    /// The pane's address or profile changed; save `state` as its `BrowserPane`.
    func browserPane(_ pane: BrowserPaneController, didChange state: BrowserPane)
    /// The pane's title (the page title, else its host; `nil` for the start
    /// page) or icon changed.
    func browserPane(_ pane: BrowserPaneController, didChangeTitle title: String?, favicon: NSImage?)
    /// The favicon last shown for a page of `url`'s site, shown until the
    /// page's own arrives.
    func rememberedFavicon(for url: String) -> NSImage?
    /// A page at `url` showed `favicon`, for the next pages of its site.
    func browserPane(_ pane: BrowserPaneController, didLoadFavicon favicon: NSImage, for url: String)
    /// The page asked to close its window: close the pane if a page opened it.
    func browserPaneRequestsClose(_ pane: BrowserPaneController)
    /// Shows a short message, such as "Copied!" or a failed download.
    func showToast(_ message: String, isError: Bool)
    /// Opens Settings → Browser.
    func manageBrowserProfiles()

    // MARK: For automation (`tab browser`)

    /// Opens a browser pane: as a new tab of Home with `newTab`; else on the
    /// `edge` (right when `nil`) of the pane `anchor` names, as `tab pane`
    /// names one, or of the pane showing the terminal or agent `beside`, else
    /// in the tab of `project` (Home when `nil`), where Home gets a new tab.
    /// Throws a message for an unknown project or pane.
    func openBrowserPane(url: String?, profile: String?, project: String?, beside: SessionId?, newTab: Bool,
                         edge: Direction?, anchor: String?) throws -> BrowserPaneController
    /// The browser panes of the named project, or of every project when both
    /// are `nil`.
    func browserTabs(project: String?, worktree: String?) throws -> [BrowserTab]
    /// The live pane for `tabId`, loading it hidden if it was never shown.
    func browserPane(tabId: String) -> BrowserPaneController?
    /// Closes the pane; `false` when there is no such browser pane.
    func closeBrowserPane(tabId: String) -> Bool
}

extension BrowserHost {
    func openBrowserPane(url: String?, profile: String?, project: String?, beside: SessionId?, newTab: Bool) throws
        -> BrowserPaneController {
        try openBrowserPane(url: url, profile: profile, project: project, beside: beside, newTab: newTab,
                            edge: nil, anchor: nil)
    }

    public func browserNetwork(forTab tabId: String) -> BrowserNetwork { .local }
    public func rememberedFavicon(for url: String) -> NSImage? { nil }
    public func browserPane(_ pane: BrowserPaneController, didLoadFavicon favicon: NSImage, for url: String) {}
    public func browserServerConnected(_ server: ServerId) -> Bool { true }
}
