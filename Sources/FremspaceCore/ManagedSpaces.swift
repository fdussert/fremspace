import Foundation

/// The Spaces of every display, parsed from what the private `CGSCopyManagedDisplaySpaces`
/// returns. Configured Spaces map to real ones by position among the *desktops* of a display:
/// native full-screen Spaces sit in the same list but are skipped (and `killall Dock` moves them
/// to the end, see docs/spikes/2026-11-spaces.md).
public struct ManagedSpaces {
    public struct Display {
        public var uuid: String
        public var current: UInt64?
        /// Space ids of the desktops (type 0), in Mission Control order.
        public var desktops: [UInt64]
        /// The macOS uuid of each desktop, parallel to `desktops`: stable when desktops are
        /// reordered. Empty when macOS gives none (the first desktop of the main display).
        public var desktopUUIDs: [String]
    }

    public var displays: [Display]

    /// Unreadable entries are dropped, so a change in the private format reads as "no Spaces".
    public init(_ raw: [[String: Any]]) {
        displays = raw.compactMap { entry in
            guard let uuid = entry["Display Identifier"] as? String,
                  let spaces = entry["Spaces"] as? [[String: Any]] else { return nil }
            let current = (entry["Current Space"] as? [String: Any]).flatMap { Self.id($0["ManagedSpaceID"]) }
            let desktops = spaces.compactMap { space -> (id: UInt64, uuid: String)? in
                guard Self.int(space["type"]) == 0, let id = Self.id(space["ManagedSpaceID"]) else { return nil }
                return (id, space["uuid"] as? String ?? "")
            }
            return Display(uuid: uuid, current: current, desktops: desktops.map(\.id), desktopUUIDs: desktops.map(\.uuid))
        }
    }

    /// The display and desktop position of a Space id; nil for a full-screen or unknown Space.
    public func desktop(ofSpace id: UInt64) -> (displayUUID: String, index: Int)? {
        for display in displays {
            if let index = display.desktops.firstIndex(of: id) {
                return (display.uuid, index)
            }
        }
        return nil
    }

    /// Display UUID → position of the desktop it shows. A display showing a full-screen Space is
    /// absent.
    public func currentDesktops() -> [String: Int] {
        var result: [String: Int] = [:]
        for display in displays {
            if let current = display.current, let index = display.desktops.firstIndex(of: current) {
                result[display.uuid] = index
            }
        }
        return result
    }

    private static func id(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value ?? (value as? UInt64)
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? Int)
    }
}
