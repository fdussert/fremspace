import Foundation

/// What Fremspace knows about one window, read through Accessibility.
public struct WindowInfo: Equatable {
    /// The CGWindowID.
    public var id: UInt32
    public var pid: Int32
    public var bundleID: String
    public var title: String
    /// A browser profile, when recognised (plan 3).
    public var profile: String?
    /// Subrole `AXStandardWindow`: dialogs, panels and sheets are never managed.
    public var isStandard: Bool
    public var isMinimized: Bool
    public var isFullScreen: Bool
    /// A browser window without a tab strip: a site's popup. It keeps its own size and place.
    public var isPopup: Bool = false
    /// Its size cannot be changed (Outlook's reminder, tool palettes): it keeps its own place.
    public var isFixedSize: Bool = false

    public init(id: UInt32, pid: Int32, bundleID: String, title: String, profile: String?,
                isStandard: Bool, isMinimized: Bool, isFullScreen: Bool) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.profile = profile
        self.isStandard = isStandard
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
    }

    /// Only these windows are placed: the others are left exactly where they are.
    public var isManageable: Bool {
        isStandard && !isMinimized && !isFullScreen && !isPopup && !isFixedSize
    }

    /// A window that can be sent to another desktop even though it cannot take a slot: a fixed-size
    /// window (Calculator) is one, a dialog or a popup is not.
    public var canChangeDesktop: Bool {
        isStandard && !isMinimized && !isFullScreen && !isPopup
    }
}

/// Chromium browsers: their normal windows have a tab strip (`AXTabGroup`), their popups do not.
/// Only these apps are checked; other apps may have no tab strip in normal windows.
public func isTabbedBrowser(_ bundleID: String) -> Bool {
    ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.dev", "com.brave.Browser.nightly",
     "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
     "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
     "org.chromium.Chromium", "com.vivaldi.Vivaldi", "company.thebrowser.Browser"]
        .contains(bundleID)
}

/// How a window is recognised across relaunches, for the "where the user last put it" memory.
public struct WindowKey: Hashable, Codable {
    public var bundleID: String
    public var profile: String?
    public var title: String

    public init(bundleID: String, profile: String?, title: String) {
        self.bundleID = bundleID
        self.profile = profile
        self.title = title
    }

    public init(_ w: WindowInfo) {
        self.init(bundleID: w.bundleID, profile: w.profile, title: w.title)
    }
}

/// Whether `w` belongs in a slot with `rule`.
public func matches(_ rule: Rule, _ w: WindowInfo) -> Bool {
    guard rule.bundleID == w.bundleID else { return false }
    if let profile = rule.profile, profile != w.profile { return false }
    if let needle = rule.titleContains, !needle.isEmpty,
       w.title.range(of: needle, options: .caseInsensitive) == nil {
        return false
    }
    return true
}

/// Whether `w` belongs in `slot` (any of its rules).
public func matches(_ slot: Slot, _ w: WindowInfo) -> Bool {
    slot.rules.contains { matches($0, w) }
}

public struct Assignment: Equatable {
    /// Window id → slot id. Several windows can share a slot (they stack).
    public var placed: [UInt32: String]
    /// Manageable windows that match no slot, in input order.
    public var unmatched: [UInt32]

    public init(placed: [UInt32: String], unmatched: [UInt32]) {
        self.placed = placed
        self.unmatched = unmatched
    }
}

/// Puts each manageable window in a slot of `layout`: the slot `memory` remembers for it when that
/// slot still exists and still matches, else the first matching slot. Minimized, full-screen and
/// non-standard windows are skipped entirely.
/// `chosen`: the slot the user dropped each live window into (by window id), which wins over the
/// title-keyed `memory` because a title changes while the window lives (a browser switching tabs).
public func assign(windows: [WindowInfo], layout: Layout, memory: [WindowKey: String],
                   chosen: [UInt32: String] = [:]) -> Assignment {
    var result = Assignment(placed: [:], unmatched: [])
    for w in windows where w.isManageable {
        let candidates = layout.slots.filter { matches($0, w) }
        if let picked = chosen[w.id], candidates.contains(where: { $0.id == picked }) {
            result.placed[w.id] = picked
        } else if let remembered = memory[WindowKey(w)], candidates.contains(where: { $0.id == remembered }) {
            result.placed[w.id] = remembered
        } else if let first = candidates.first {
            result.placed[w.id] = first.id
        } else {
            result.unmatched.append(w.id)
        }
    }
    return result
}
