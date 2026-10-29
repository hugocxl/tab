import AppKit
import TabCore

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

/// What browser panes and `BrowserAutomation` need from the app shell. The
/// shell owns panes, layouts and saving; the browser owns pages.
@MainActor
public protocol BrowserHost: AnyObject {
    var theme: AppTheme { get }
    /// The browser settings in effect.
    var browserSettings: BrowserSettings { get }
    var browserProfiles: BrowserProfiles { get }

    // MARK: From a pane

    /// A page opened a window: show `url` in a new browser pane next to
    /// `source`, with `profile` (a profile id).
    func openBrowserPane(url: String, profile: String, from source: BrowserPaneController)
    /// The pane's address or profile changed; save `state` as its `BrowserPane`.
    func browserPane(_ pane: BrowserPaneController, didChange state: BrowserPane)
    /// The pane's title (the page title, else its host; `nil` for the start
    /// page) or icon changed.
    func browserPane(_ pane: BrowserPaneController, didChangeTitle title: String?, favicon: NSImage?)
    /// The page asked to close its window: close the pane if a page opened it.
    func browserPaneRequestsClose(_ pane: BrowserPaneController)
    /// Shows a short message, such as "Copied!" or a failed download.
    func showToast(_ message: String, isError: Bool)
    /// Opens Settings → Browser.
    func manageBrowserProfiles()

    // MARK: For automation (`tab browser`)

    /// Opens a browser pane in the project `project` and `worktree` name (the
    /// current project when both are `nil`), splitting when `split`. Throws a
    /// message for an unknown project.
    func openBrowserPane(url: String?, profile: String?, project: String?, worktree: String?, split: Bool) throws
        -> BrowserPaneController
    /// The browser panes of the named project, or of every project when both
    /// are `nil`.
    func browserTabs(project: String?, worktree: String?) throws -> [BrowserTab]
    /// The live pane for `tabId`, loading it hidden if it was never shown.
    func browserPane(tabId: String) -> BrowserPaneController?
    /// Closes the pane; `false` when there is no such browser pane.
    func closeBrowserPane(tabId: String) -> Bool
}
