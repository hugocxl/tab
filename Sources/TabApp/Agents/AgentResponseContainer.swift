import AppKit

/// Nested blocks reuse the same interactive code/table renderer as root blocks.
@MainActor
final class AgentResponseContainer: AgentResponseSection {
    override var kind: Int { 3 }
    let response = AgentResponseView(frame: .zero)
    private let alertIcon = NSImageView()
    private let marker = makeLabel("", font: AppFont.system(14))
    let disclosure = PillButton("", style: .plain)
    private var container: AgentResponsePart.Container?
    private var expanded = false
    private var leading: CGFloat = 16
    private var top: CGFloat = 0
    private var titleColor: NSColor = .labelColor
    private var border: NSColor = .separatorColor
    private var taskState: Int?
    private var taskIndent: CGFloat = 0
    private var bullet: String?
    private var orderedMarker: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        marker.translatesAutoresizingMaskIntoConstraints = true
        disclosure.translatesAutoresizingMaskIntoConstraints = true
        disclosure.alignment = .left
        disclosure.font = AppFont.system(14, weight: .medium)
        addSubview(marker); addSubview(disclosure); addSubview(response); addSubview(alertIcon)
        response.onHeightChanged = { [weak self] in self?.changed() }
        disclosure.onPress = { [weak self] in
            guard let self else { return }
            self.expanded.toggle()
            self.refreshDisclosure()
            self.changed()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func changed() { invalidateMeasurement(); onHeightChanged?() }
    func reveal() {
        guard case .details = container, !expanded else { return }
        expanded = true
        refreshDisclosure()
        changed()
    }
    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        let next: AgentResponsePart.Container
        switch part {
        case .container(let kind, _), .nested(let kind, _): next = kind
        default: return
        }
        let wasDetails: Bool
        if case .details = container { wasDetails = true } else { wasDetails = false }
        container = next
        titleColor = theme.fg
        border = theme.border.withAlphaComponent(0.6)
        marker.textColor = AgentMarkdownPalette(theme: theme).body
        marker.isHidden = true
        taskState = nil
        bullet = nil
        orderedMarker = nil
        setAccessibilityLabel(nil)
        marker.font = AppFont.system(compactProse ? 12 : 14)
        alertIcon.isHidden = true
        disclosure.isHidden = true
        response.isHidden = false
        top = 0
        switch next {
        case .quote: leading = AgentMarkdownLayout.units(14.8); border = AgentMarkdownPalette(theme: theme).quoteRule
        case .alert(let title):
            leading = 12; top = 28
            let icon: String
            switch title {
            case "Tip": border = .systemGreen; icon = "lightbulb"
            case "Important": border = .systemPurple; icon = "text.bubble"
            case "Warning": border = .systemOrange; icon = "exclamationmark.triangle"
            case "Caution": border = .systemRed; icon = "exclamationmark.octagon"
            default: border = .systemBlue; icon = "info.circle"
            }
            marker.stringValue = title; marker.textColor = border
            marker.font = AppFont.system(14, weight: .medium)
            marker.isHidden = false; alertIcon.isHidden = false
            alertIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            alertIcon.contentTintColor = border
        case .list(let text, let depth, let indent, let structure):
            leading = indent ?? CGFloat(depth + 1) * 20
            marker.stringValue = text
            marker.isHidden = false
            if AgentListBullet.recognizes(text) {
                bullet = text
                marker.isHidden = true
            }
            if text.hasSuffix(".") {
                orderedMarker = text
                marker.isHidden = true
            }
            taskState = AgentTaskCheckbox.state(marker: text, dark: !theme.palette.isLight)
            if taskState != nil {
                taskIndent = leading - AgentListLayout.gutter(structure: structure, blocks: [], font: AppFont.system(compactProse ? 12 : 14))
                leading = taskIndent + AgentTaskCheckbox.textInset(font: AppFont.system(compactProse ? 12 : 14))
                marker.isHidden = true
                setAccessibilityLabel(text == "☑" ? "Completed task" : "Incomplete task")
            } else { setAccessibilityLabel(nil) }
        case .details(_, let initiallyOpen):
            if !wasDetails { expanded = initiallyOpen }
            leading = 24; top = 36
            disclosure.isHidden = false
        }
        switch part {
        case .container(_, let source): response.setContent(source, theme: theme)
        case .nested(_, let blocks): response.setPreparedContent(blocks, theme: theme)
        default: break
        }
        refreshDisclosure()
        disclosure.setTitleColor(theme.fg)
        needsDisplay = true
    }
    private func refreshDisclosure() {
        guard case .details(let title, _) = container else { return }
        disclosure.title = (expanded ? "⌄  " : "›  ") + title
        disclosure.setTitleColor(titleColor)
        disclosure.setAccessibilityLabel((expanded ? "Collapse " : "Expand ") + title)
        response.isHidden = !expanded
    }
    override func height(for width: CGFloat) -> CGFloat {
        if response.isHidden { return top + 1 }
        return top + response.height(for: max(1, width - leading)) + (top > 0 ? 12 : 0)
    }
    override func layoutSection(width: CGFloat) {
        if case .alert = container {
            marker.frame = NSRect(x: leading + 20, y: 0, width: max(0, width - leading - 20), height: 22)
            alertIcon.frame = NSRect(x: leading, y: 3, width: 14, height: 14)
        } else { marker.frame = NSRect(x: max(0, leading - 24), y: 0, width: 22, height: 22) }
        disclosure.frame = NSRect(x: 0, y: 3, width: width, height: 30)
        response.frame = NSRect(x: leading, y: top, width: max(1, width - leading), height: max(0, bounds.height - top - (top > 0 ? 12 : 0)))
        response.layoutSubtreeIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if bullet != nil || orderedMarker != nil {
            func firstText(in view: NSView) -> AgentRichTextView? {
                if let text = view as? AgentRichTextView, !text.string.isEmpty { return text }
                for child in view.subviews { if let text = firstText(in: child) { return text } }
                return nil
            }
            var baseline: CGFloat = compactProse ? 14 : 16
            if let text = firstText(in: response), let manager = text.layoutManager, manager.numberOfGlyphs > 0 {
                baseline = text.convert(NSPoint.zero, to: self).y + manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + manager.location(forGlyphAt: 0).y
            }
            if let bullet {
                AgentListBullet.draw(bullet, rect: AgentListBullet.rect(textX: leading, baseline: baseline, font: AppFont.system(compactProse ? 12 : 14)), color: marker.textColor ?? .labelColor)
            }
            if let orderedMarker {
                let font = NSFont.monospacedDigitSystemFont(ofSize: compactProse ? 12 : 14, weight: .regular)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: marker.textColor ?? .labelColor]
                let width = ((orderedMarker + " ") as NSString).size(withAttributes: attributes).width
                (orderedMarker as NSString).draw(at: NSPoint(x: leading - width, y: baseline - font.ascender), withAttributes: attributes)
            }
        }
        if let taskState {
            AgentTaskCheckbox.draw(state: taskState, in: NSRect(x: taskIndent, y: AgentTaskCheckbox.top,
                width: AgentTaskCheckbox.size, height: AgentTaskCheckbox.size))
        }
        border.setFill()
        switch container {
        case .quote, .alert: NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        case .details:
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        default: break
        }
    }
    override func captureState() -> AgentResponseState {
        var state = response.captureState()
        state.expanded = expanded
        return state
    }
    override func restoreState(_ state: AgentResponseState) {
        if let expanded = state.expanded { self.expanded = expanded }
        response.restoreState(state)
        refreshDisclosure()
        invalidateMeasurement()
    }
}
