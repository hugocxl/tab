import AppKit

/// Table copy controls occupy the conversation lane's four-point side gutter.
/// Route those controls directly when an intermediate text section rejects a hit
/// outside its bounds, while retaining every enclosing scroll viewport's clipping.
@MainActor
enum AgentTableCopyHitTesting {
    /// `point` uses the receiver's superview coordinates, like `NSView.hitTest`.
    static func hitTest(_ point: NSPoint, in receiver: NSView) -> NSView? {
        let local = receiver.convert(point, from: receiver.superview)
        return findControl(at: local, in: receiver, relativeTo: receiver)
    }

    private static func findControl(at point: NSPoint, in view: NSView, relativeTo source: NSView) -> NSView? {
        guard !view.isHidden, view.alphaValue > 0 else { return nil }
        if let table = view as? AgentResponseTable {
            let control = table.copy
            guard control.isEnabled, !control.isHiddenOrHasHiddenAncestor, control.alphaValue > 0,
                  control.bounds.contains(control.convert(point, from: source)) else { return nil }
            var ancestor: NSView? = control.superview
            while let current = ancestor {
                guard !current.isHidden, current.alphaValue > 0 else { return nil }
                if current is NSClipView || current.clipsToBounds || current.layer?.masksToBounds == true {
                    guard current.bounds.contains(current.convert(point, from: source)) else { return nil }
                }
                ancestor = current.superview
            }
            return control
        }
        for child in view.subviews.reversed() {
            if let result = findControl(at: point, in: child, relativeTo: source) { return result }
        }
        return nil
    }
}
