import AppKit

/// The look every image, file and media attachment of the agent pane shares: the
/// composer's chips, a message's images and files, tool images, and the assistant's
/// media and documents.
@MainActor
enum AgentMediaStyle {
    /// The corner of every attachment card and image frame.
    static let radius: CGFloat = 10
    /// Between the tiles of a mosaic, where the pane shows through.
    nonisolated static let gap: CGFloat = 2
    /// The side of a card's icon or thumbnail box.
    static let iconBox: CGFloat = 36
    /// A preview that couldn't load, or that waits for a click, as a short card.
    nonisolated static let compactHeight: CGFloat = 56
    static let compactWidth: CGFloat = 260

    /// The fill of cards, and of image tiles before their image arrives.
    static func fill(_ theme: AppTheme) -> NSColor { theme.fg.withAlphaComponent(0.055) }
    /// The fill of a card's icon box.
    static func iconFill(_ theme: AppTheme) -> NSColor { theme.fg.withAlphaComponent(0.06) }
    /// The edge of an image frame.
    static func hairline(_ theme: AppTheme) -> NSColor { theme.border.withAlphaComponent(0.7) }

    /// Rounds and clips `view` as a frame of image tiles, edged by a hairline.
    static func applyFrame(to view: NSView, theme: AppTheme) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = hairline(theme).cgColor
        layer.backgroundColor = NSColor.clear.cgColor
    }

    /// Rounds `view` as a card: a faint fill and no edge.
    static func applyCard(to view: NSView, theme: AppTheme) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 0
        layer.backgroundColor = fill(theme).cgColor
    }

    /// `pixelSize` scaled down to fit `maxWidth` × `maxHeight`, never up.
    static func fittedSize(_ pixelSize: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return NSSize(width: max(1, maxWidth), height: max(1, maxHeight)) }
        let scale = min(1, max(1, maxWidth) / pixelSize.width, maxHeight / pixelSize.height)
        return NSSize(width: max(1, floor(pixelSize.width * scale)), height: max(1, floor(pixelSize.height * scale)))
    }

    /// The short cards of previews that couldn't load, one under another.
    static func compactSize(count: Int, width: CGFloat) -> NSSize {
        let count = CGFloat(max(1, count))
        return NSSize(width: min(width, compactWidth), height: count * compactHeight + (count - 1) * gap)
    }

    static func compactFrames(count: Int, width: CGFloat) -> [NSRect] {
        (0..<count).map { NSRect(x: 0, y: CGFloat($0) * (compactHeight + gap), width: width, height: compactHeight) }
    }
}

/// Several images as one mosaic: two side by side, three as one large and two small,
/// four or more in two columns where an odd last tile spans the row.
struct AgentMediaCollage: Sendable {
    /// The height of a mosaic of two or three.
    var pairHeight: CGFloat
    /// The height of each row of four or more.
    var rowHeight: CGFloat

    /// The assistant's media, in the reading column.
    static let response = AgentMediaCollage(pairHeight: 240, rowHeight: 160)
    /// A message's own images and a tool's, which sit beside text and stay smaller.
    static let compact = AgentMediaCollage(pairHeight: 180, rowHeight: 120)

    func height(count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        if count <= 3 { return pairHeight }
        let rows = CGFloat((count + 1) / 2)
        return rows * rowHeight + (rows - 1) * AgentMediaStyle.gap
    }

    func frames(count: Int, width: CGFloat) -> [NSRect] {
        let gap = AgentMediaStyle.gap
        let half = (width - gap) / 2
        return (0..<count).map { index in
            switch count {
            case 1: return NSRect(x: 0, y: 0, width: width, height: pairHeight)
            case 2: return NSRect(x: CGFloat(index) * (half + gap), y: 0, width: half, height: pairHeight)
            case 3:
                let first = floor((width - gap) * 0.6)
                let small = (pairHeight - gap) / 2
                return index == 0 ? NSRect(x: 0, y: 0, width: first, height: pairHeight)
                    : NSRect(x: first + gap, y: CGFloat(index - 1) * (small + gap), width: width - first - gap, height: small)
            default:
                let spans = count % 2 == 1 && index == count - 1
                return NSRect(x: spans ? 0 : CGFloat(index % 2) * (half + gap), y: CGFloat(index / 2) * (rowHeight + gap),
                              width: spans ? width : half, height: rowHeight)
            }
        }
    }
}
