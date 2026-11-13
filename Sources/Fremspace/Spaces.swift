import CoreGraphics
import Foundation
import FremspaceCore

/// Which desktop each display shows, and which desktop a window is on, read with private SkyLight
/// calls (`PrivateCalls`: CGSMainConnectionID, CGSCopyManagedDisplaySpaces, CGSCopySpacesForWindows).
/// There is no public API for Spaces; these are the ones every macOS window manager reads, and the
/// Task 0 spike checked them on macOS 27 without SIP changes. Any failure, a call that this macOS
/// no longer has included, reads as empty / nil, which the engine treats as free: nothing is placed.
enum Spaces {
    /// Current, other and user Spaces.
    private static let allSpacesMask: Int32 = 0x7

    /// Fremspace's connection to the window server, for the other private calls; nil when the
    /// call that gives it is missing.
    static var connection: Int32? { PrivateCalls.mainConnectionID?() }

    static func managed() -> ManagedSpaces {
        guard let connection = connection, let copy = PrivateCalls.copyManagedDisplaySpaces else { return ManagedSpaces([]) }
        return ManagedSpaces(copy(connection)?.takeRetainedValue() as? [[String: Any]] ?? [])
    }

    /// The Space ids of a window, as the window server gives them.
    private static func spaces(ofWindow id: UInt32) -> [NSNumber] {
        guard let connection = connection, let copy = PrivateCalls.copySpacesForWindows else { return [] }
        return copy(connection, allSpacesMask, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
    }

    /// Display → position of the desktop it shows. A display on a full-screen Space is absent.
    static func current() -> [DisplayIdentity: Int] {
        let byUUID = Dictionary(Displays.connected().map { ($0.uuid, $0.identity) }, uniquingKeysWith: { a, _ in a })
        var result: [DisplayIdentity: Int] = [:]
        for (uuid, index) in managed().currentDesktops() {
            if let identity = byUUID[uuid] { result[identity] = index }
        }
        return result
    }

    /// The Space ids (`ManagedSpaceID`) a window is on: one for a normal window, several for a
    /// window on all desktops, none for an unknown one.
    static func spaceIDs(ofWindow id: UInt32) -> [UInt64] {
        spaces(ofWindow: id).map(\.uint64Value)
    }

    /// The Space id of the desktop at real position `real` of a display.
    static func spaceID(display: DisplayIdentity, real: Int) -> UInt64? {
        guard let uuid = Displays.connected().first(where: { $0.identity == display })?.uuid,
              let live = managed().displays.first(where: { $0.uuid == uuid }), real < live.desktops.count else { return nil }
        return live.desktops[real]
    }

    static func spaceIndex(ofWindow id: UInt32) -> SpaceKey? {
        spaceIndex(ofWindow: id, managed: managed(), displays: Displays.connected())
    }

    /// Same, with Spaces and displays read once by the caller for a whole pass.
    static func spaceIndex(ofWindow id: UInt32, managed: ManagedSpaces, displays: [Displays.Connected]) -> SpaceKey? {
        let ids = spaces(ofWindow: id)
        // A window on several Spaces ("all desktops") belongs to none of them.
        guard ids.count == 1, let desktop = managed.desktop(ofSpace: ids[0].uint64Value) else { return nil }
        guard let display = displays.first(where: { $0.uuid == desktop.displayUUID }) else { return nil }
        return SpaceKey(display: display.identity, spaceIndex: desktop.index)
    }
}
