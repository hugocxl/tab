import AppKit
import QuartzCore
import TabCore

/// Compositor-only transitions: the terminal receives its final size once.
@MainActor
enum InterfaceMotion {
    static func duration(_ style: InterfaceAnimation) -> TimeInterval {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        switch style {
        case .snappy: return 0.18
        case .natural: return 0.32
        case .off: return 0
        }
    }

    static func frame(_ view: NSView) -> CGRect {
        view.layer?.presentation()?.frame ?? view.frame
    }

    static func cancel(in view: NSView) {
        view.layer?.removeAnimation(forKey: "interface")
        for child in view.subviews {
            if child is MotionSnapshot { child.removeFromSuperview() } else { cancel(in: child) }
        }
    }

    static func animate(_ view: NSView, from previous: CGRect?, style: InterfaceAnimation) {
        guard let layer = view.layer else { return }
        let duration = duration(style)
        guard duration > 0, view.window != nil, view.frame.width > 0, view.frame.height > 0 else {
            layer.removeAnimation(forKey: "interface")
            return
        }
        let target = view.frame
        let group = CAAnimationGroup()
        var animations: [CAAnimation] = []
        let transform = CABasicAnimation(keyPath: "transform")
        if let previous, previous.width > 0, previous.height > 0 {
            guard previous != target else { return }
            transform.fromValue = CATransform3DMakeScale(previous.width / target.width, previous.height / target.height, 1)
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = CGPoint(x: layer.position.x + previous.minX - target.minX,
                                         y: layer.position.y + previous.minY - target.minY)
            position.toValue = layer.position
            animations.append(position)
        } else {
            transform.fromValue = CATransform3DMakeScale(0.97, 0.97, 1)
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0
            opacity.toValue = 1
            animations.append(opacity)
        }
        transform.toValue = CATransform3DIdentity
        animations.append(transform)
        group.animations = animations
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(group, forKey: "interface")
    }

    /// An outgoing image never retains a pane controller or accepts input.
    static func dismiss(_ view: NSView, style: InterfaceAnimation, slide: CGFloat = 0) {
        let duration = duration(style)
        guard duration > 0, view.window != nil, !view.isHidden, let parent = view.superview,
              view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let ghost = MotionSnapshot(frame: view.frame)
        ghost.image = image
        ghost.imageScaling = .scaleAxesIndependently
        ghost.wantsLayer = true
        parent.addSubview(ghost, positioned: .above, relativeTo: view)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            ghost.animator().alphaValue = 0
            ghost.animator().frame = ghost.frame.offsetBy(dx: slide, dy: slide == 0 ? 6 : 0)
        } completionHandler: {
            ghost.removeFromSuperview()
        }
    }
}

private final class MotionSnapshot: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
