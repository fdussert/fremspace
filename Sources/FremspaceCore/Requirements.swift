import CoreGraphics
import Foundation

/// A connected display with fewer desktops than its configuration lists.
public struct MissingDesktops: Equatable {
    public var display: DisplayIdentity
    public var needed: Int
    public var present: Int

    public init(display: DisplayIdentity, needed: Int, present: Int) {
        self.display = display
        self.needed = needed
        self.present = present
    }
}

/// Displays of `configuration` that are connected (present in `present`, desktops only), not ignored,
/// and have fewer desktops than configured.
public func missingDesktops(_ configuration: Configuration, present: [DisplayIdentity: Int]) -> [MissingDesktops] {
    configuration.displays.compactMap { spec in
        guard !spec.ignored, let count = present[spec.identity], count < spec.spaces.count else { return nil }
        return MissingDesktops(display: spec.identity, needed: spec.spaces.count, present: count)
    }
}

/// The smallest size each app accepted, learned from placements it refused (Accessibility does not
/// expose minimum sizes).
public struct MinimumSizes {
    private var sizes: [String: CGSize] = [:]

    public init() {}

    /// Records what a refused placement teaches: only the dimensions where the window stayed larger
    /// than requested are minimums (in the other one it simply took the slot's size).
    public mutating func record(bundleID: String, requested: CGSize, actual: CGSize, tolerance: CGFloat) {
        let width = actual.width > requested.width + tolerance ? actual.width : 0
        let height = actual.height > requested.height + tolerance ? actual.height : 0
        guard width > 0 || height > 0 else { return }
        record(bundleID: bundleID, size: CGSize(width: width, height: height))
    }

    public mutating func record(bundleID: String, size: CGSize) {
        let old = sizes[bundleID] ?? .zero
        sizes[bundleID] = CGSize(width: max(old.width, size.width), height: max(old.height, size.height))
    }

    public func minimum(for bundleID: String) -> CGSize? {
        sizes[bundleID]
    }
}

/// Slots whose frame is smaller than their app's known minimum, with that minimum.
public func tooSmall(_ frames: [String: CGRect], layout: Layout, minimums: MinimumSizes) -> [String: CGSize] {
    var result: [String: CGSize] = [:]
    for slot in layout.slots {
        guard let frame = frames[slot.id] else { continue }
        // Several apps can stack in a slot: the most demanding one decides.
        let known = slot.rules.compactMap { minimums.minimum(for: $0.bundleID) }
        guard !known.isEmpty else { continue }
        let minimum = CGSize(width: known.map(\.width).max() ?? 0, height: known.map(\.height).max() ?? 0)
        if frame.width < minimum.width || frame.height < minimum.height { result[slot.id] = minimum }
    }
    return result
}

/// Mission Control's "Automatically rearrange Spaces based on most recent use" (Dock key
/// `mru-spaces`, on when unset) moves desktops around as apps are activated. Fremspace finds a
/// desktop by its position on its display, so with it on, layouts land on the wrong desktops.
public enum SpacesOrder {
    public static let message = "Turn off \u{201C}Automatically rearrange Spaces\u{201D} (Desktop & Dock \u{2192} Mission Control): it reorders desktops"

    /// `mruSpaces`: the raw `com.apple.dock` `mru-spaces` value (nil when unset).
    public static func warning(mruSpaces: Any?) -> String? {
        guard let value = mruSpaces else { return message }
        if let flag = value as? Bool { return flag ? message : nil }
        if let number = value as? NSNumber { return number.boolValue ? message : nil }
        return message
    }
}
