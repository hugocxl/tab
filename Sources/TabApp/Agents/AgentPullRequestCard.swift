import AppKit
import TabCore
import TabProtocol

/// What a pull-request card shows for one preview state, independent of views.
struct AgentPullRequestCardContent: Equatable {
    enum Style: Equatable { case loading, loaded, failed }
    enum Status: String, Equatable { case open, closed, merged, draft }

    var style: Style
    var title: String
    var detail: String
    var status: Status?
    var initials: String?
    var toolTip: String?

    var statusLabel: String? { status.map { $0.rawValue.capitalized } }

    @MainActor
    static func make(url: URL, state: AgentLazyRequestCache<GitPullRequestPreview>.State?, now: Date = Date()) -> Self {
        let target = AgentConversationPullRequestPreview.target(from: url)
        let reference = target.map { "\($0.repository) #\($0.number)" } ?? url.absoluteString
        switch state {
        case .none, .loading?:
            return Self(style: .loading, title: reference, detail: "Loading pull request…", toolTip: url.absoluteString)
        case .failed(let message)?:
            return Self(style: .failed, title: url.absoluteString, detail: "", toolTip: message)
        case .loaded(let preview)?:
            var details = ["\(preview.repository) #\(preview.number)"]
            if let login = preview.author?.login, !login.isEmpty { details.append(login) }
            if let created = relativeDate(preview.createdAt, now: now) { details.append(created) }
            let status: Status = preview.state == .open && preview.isDraft ? .draft
                : preview.state == .merged ? .merged : preview.state == .closed ? .closed : .open
            return Self(style: .loaded, title: preview.title, detail: details.joined(separator: " · "), status: status,
                        initials: preview.author.map { initials(login: $0.login, name: $0.name) }, toolTip: preview.url)
        }
    }

    /// Two letters from the author's name, or the first letter of the login.
    static func initials(login: String, name: String?) -> String {
        let words = (name ?? "").split(whereSeparator: { $0.isWhitespace }).compactMap(\.first)
        if words.count >= 2 { return String(words.prefix(2)).uppercased() }
        if let first = words.first { return String(first).uppercased() }
        return login.first.map { String($0).uppercased() } ?? "?"
    }

    /// "3 days ago" for an ISO 8601 creation time; nil when it cannot be read.
    @MainActor static func relativeDate(_ value: String, now: Date) -> String? {
        guard let date = isoFormatter.date(from: value) ?? isoFractionalFormatter.date(from: value) else { return nil }
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    @MainActor private static let isoFormatter = ISO8601DateFormatter()
    @MainActor private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

/// A bare pull-request link of an assistant paragraph, shown as a compact card below it.
/// The preview is requested once per URL per conversation, only while the card is in a
/// window; until it arrives the card is a quiet placeholder of constant height, and a
/// failed preview falls back to a plain link with the error as its tooltip.
@MainActor
final class AgentResponsePullRequest: AgentResponseSection {
    override var kind: Int { 8 }
    static let height: CGFloat = 56
    weak var services: AgentConversationLinkServices? {
        didSet { if oldValue !== services { resubscribe() } }
    }
    private(set) var url: URL?
    private(set) var content: AgentPullRequestCardContent?
    private var observation: AgentLazyRequestObservation?
    private var theme: AppTheme?
    /// The theme whose colors are currently applied, so a theme change repaints unchanged content.
    private var appliedTheme: ObjectIdentifier?
    private let title = makeLabel("", font: AppFont.system(13, weight: .medium))
    private let detail = makeLabel("", font: AppFont.footnote)
    private let pill = makeLabel("", font: AppFont.system(10, weight: .semibold))
    private let avatar = makeLabel("", font: AppFont.system(8, weight: .semibold))
    private let linkIcon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        pill.alignment = .center
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 4
        avatar.alignment = .center
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 7
        for child in [title, detail, pill, avatar, linkIcon] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .pullRequest(let raw) = part, let next = URL(string: raw) else { return }
        self.theme = theme
        if next != url {
            url = next
            resubscribe()
        }
        render(services?.pullRequests.state(for: next.absoluteString))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resubscribe()
    }

    /// Observes the preview only while the card is materialized in a window.
    private func resubscribe() {
        observation?.cancel()
        observation = nil
        guard window != nil, let url, let services else { return }
        observation = services.pullRequests.observe(url.absoluteString) { [weak self] state in self?.render(state) }
    }

    private func render(_ state: AgentLazyRequestCache<GitPullRequestPreview>.State?) {
        guard let url, let theme else { return }
        let next = AgentPullRequestCardContent.make(url: url, state: state)
        let themeIdentity = ObjectIdentifier(theme)
        guard next != content || themeIdentity != appliedTheme else { return }
        content = next
        appliedTheme = themeIdentity
        title.stringValue = next.title
        detail.stringValue = next.detail
        toolTip = next.toolTip
        setAccessibilityLabel(next.style == .loaded ? "Pull request \(next.detail): \(next.title)" : next.title)
        let failed = next.style == .failed
        layer?.backgroundColor = failed ? NSColor.clear.cgColor : theme.fg.withAlphaComponent(0.035).cgColor
        layer?.borderWidth = failed ? 0 : 1
        layer?.borderColor = theme.border.withAlphaComponent(0.7).cgColor
        let palette = AgentMarkdownPalette(theme: theme)
        title.textColor = failed ? palette.link : next.style == .loading ? theme.fgMuted : theme.fg
        title.font = failed ? AppFont.system(13) : AppFont.system(13, weight: .medium)
        detail.textColor = theme.fgMuted
        detail.isHidden = failed
        linkIcon.isHidden = !failed
        linkIcon.image = AppIcon.externalLink.image(size: 12, scale: AppIcon.inlineScale, color: palette.link)
        if let status = next.status, let label = next.statusLabel {
            let color = Self.color(status, theme: theme)
            pill.stringValue = label
            pill.textColor = color
            pill.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
            pill.isHidden = false
        } else { pill.isHidden = true }
        avatar.isHidden = next.initials == nil
        avatar.stringValue = next.initials ?? ""
        avatar.textColor = theme.fgMuted
        avatar.layer?.backgroundColor = theme.fg.withAlphaComponent(0.1).cgColor
        invalidateMeasurement()
        needsLayout = true
    }

    /// Open is the diff-add green, closed the danger red, merged the theme's magenta.
    static func color(_ status: AgentPullRequestCardContent.Status, theme: AppTheme) -> NSColor {
        switch status {
        case .open: return theme.diffAdd
        case .closed: return theme.danger
        case .merged: return theme.scheme.paletteColor(5).map { ChromeColor($0).nsColor } ?? theme.accent
        case .draft: return theme.fgMuted
        }
    }

    override func height(for width: CGFloat) -> CGFloat { Self.height }

    override func layoutSection(width: CGFloat) {
        let inset: CGFloat = 12
        if content?.style == .failed {
            linkIcon.frame = NSRect(x: 0, y: 22, width: 12, height: 12)
            title.frame = NSRect(x: 18, y: 19, width: max(0, width - 18), height: 18)
            return
        }
        var titleX = inset
        if !pill.isHidden {
            let pillWidth = ceil(pill.intrinsicContentSize.width) + 10
            pill.frame = NSRect(x: inset, y: 11, width: pillWidth, height: 16)
            titleX += pillWidth + 8
        }
        title.frame = NSRect(x: titleX, y: 9, width: max(0, width - titleX - inset), height: 18)
        var detailX = inset
        if !avatar.isHidden {
            avatar.frame = NSRect(x: inset, y: 32, width: 14, height: 14)
            detailX += 20
        }
        detail.frame = NSRect(x: detailX, y: 31, width: max(0, width - detailX - inset), height: 16)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let url, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open(url)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let url else { return false }
        open(url)
        return true
    }

    private func open(_ url: URL) {
        if let openLink = services?.openLink { openLink(url.absoluteString) }
        else { NSWorkspace.shared.open(url) }
    }
}
