import AppKit

/// Runs a closure as a control's action; kept alive by the control.
final class BlockTarget: NSObject {
    private let block: () -> Void
    private static var key = 0

    private init(_ block: @escaping () -> Void) { self.block = block }

    @objc func run() { block() }

    /// Makes a target for `control` and ties its life to the control's.
    static func attach(to control: NSControl, _ block: @escaping () -> Void) -> BlockTarget {
        let target = BlockTarget(block)
        objc_setAssociatedObject(control, &key, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return target
    }
}
