import CoreGraphics
import Foundation

public enum LockAction: Equatable {
    /// Leave the window alone.
    case none
    /// Put the window back to this frame.
    case restore(CGRect)
    /// The window keeps fighting the lock (an app with a minimum size, one that resizes itself):
    /// stop managing it rather than loop.
    case release
}

/// Decides what to do when a window in a locked slot changes frame.
public struct LockGuard {
    public let tolerance: CGFloat
    public let maxRestores: Int
    public let window: TimeInterval

    private var restores: [UInt32: [Date]] = [:]
    private var released: Set<UInt32> = []

    public init(tolerance: CGFloat = 2, maxRestores: Int = 3, window: TimeInterval = 5) {
        self.tolerance = tolerance
        self.maxRestores = maxRestores
        self.window = window
    }

    /// No snap-back while the mouse button is down (the user is still dragging); after release, a
    /// restore, unless the window was already restored `maxRestores` times in the last `window`
    /// seconds, in which case it is released for good (until `forget`).
    public mutating func frameChanged(id: UInt32, actual: CGRect, expected: CGRect, mouseDown: Bool,
                                      now: Date) -> LockAction {
        if released.contains(id) { return .none }
        if isClose(actual, expected) { return .none }
        if mouseDown { return .none }
        let recent = (restores[id] ?? []).filter { now.timeIntervalSince($0) < window }
        if recent.count >= maxRestores {
            released.insert(id)
            restores[id] = nil
            return .release
        }
        restores[id] = recent + [now]
        return .restore(expected)
    }

    /// The window is gone: drop everything known about it.
    public mutating func forget(id: UInt32) {
        restores[id] = nil
        released.remove(id)
    }

    /// The owner took the window out of its slot on purpose (a quick resize): left alone until
    /// `endReleases` (⌃⌥⌘R).
    public mutating func release(_ id: UInt32) {
        released.insert(id)
        restores[id] = nil
    }

    /// An explicit re-apply: every released window is managed again, with its restore count reset.
    public mutating func endReleases() {
        released.removeAll()
        restores.removeAll()
    }

    public var releasedCount: Int { released.count }

    public var releasedIDs: Set<UInt32> { released }

    public func isReleased(_ id: UInt32) -> Bool {
        released.contains(id)
    }

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
