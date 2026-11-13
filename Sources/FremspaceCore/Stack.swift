import Foundation

/// The windows of one slot stack. The window to show after `current` when the owner goes through the
/// stack: the next one in a fixed order (window ids, so the order does not change as windows come to
/// the front), wrapping around. Nil when there is no other window, or `current` is not in the stack.
public func nextInStack(_ windows: [UInt32], after current: UInt32, forward: Bool = true) -> UInt32? {
    let order = Set(windows).sorted()
    guard order.count > 1, let index = order.firstIndex(of: current) else { return nil }
    return order[(index + (forward ? 1 : order.count - 1)) % order.count]
}
