import Foundation

/// Whether a locked window's placement may still be enforced (restored, dropped into a slot).
/// Only while the engine runs, and only while the window is still on the Space it was placed on:
/// a window the user took to another desktop or display, into native full screen, or whose display
/// is gone (`windowSpace == nil`) is no longer the engine's to move.
public func mayEnforce(running: Bool, windowSpace: SpaceKey?, placedSpace: SpaceKey) -> Bool {
    running && windowSpace == placedSpace
}

/// What a locked window that left its slot frame may be taken for, beyond a move to undo.
public struct HandChange: Equatable {
    /// It may have been dropped into another slot that takes it.
    public var mayDropIntoSlot: Bool
    /// It may have been resized by an edge its slot shares with others: the layout follows.
    public var mayResizeLayout: Bool
}

/// Only what the owner did with the mouse chooses another slot or resizes the layout: `dragged`
/// is true when the change was seen while the button was down and is judged on its release. A
/// window also changes its own frame (a terminal growing with its font, a player sizing to its
/// video, an app settling a moment after it was placed): that is put back like any other move, and
/// never chooses a slot nor rewrites the configuration file. `moved`: same size, another place
/// (`isMove`); `resizeLayouts`: the general setting.
public func handChange(dragged: Bool, moved: Bool, resizeLayouts: Bool) -> HandChange {
    HandChange(mayDropIntoSlot: dragged && moved, mayResizeLayout: dragged && resizeLayouts)
}

/// What to do about a window whose move into its slot Accessibility refused (its app was busy:
/// at launch, at login).
public enum MoveRetry: Equatable {
    /// The window does not hold its slot yet: a pass runs again after this long and plans the
    /// move anew. Held, an unlocked slot's window would be left where it is for good.
    case again(after: TimeInterval)
    /// Refused too often: the window counts as placed where it is, like one that will not take
    /// its frame, rather than being moved at every pass.
    case giveUp
}

/// `failures`: the moves of this window refused in a row, this one included.
public func moveRetry(failures: Int) -> MoveRetry {
    switch failures {
    case ...1: return .again(after: 1)
    case 2: return .again(after: 3)
    default: return .giveUp
    }
}

/// What the engine does after reading a placed window back.
public enum FitAction: Equatable {
    /// It took its slot frame: stays locked.
    case keepLock
    /// It will not take its slot frame (minimum size, resize steps, fixed size): left where it
    /// settled and no longer locked, rather than fought on every pass.
    case unlock
    /// Set the frame again.
    case resizeAgain
}

public func fitAction(_ verdict: FitVerdict, retriesLeft: Int) -> FitAction {
    switch verdict {
    case .fits: return .keepLock
    case .refuses: return .unlock
    case .resizeAgain: return retriesLeft > 0 ? .resizeAgain : .unlock
    }
}
