import AppKit
import FremspaceCore

/// The connected displays, identified by what they are.
enum Displays {
    struct Connected {
        var identity: DisplayIdentity
        /// The visible frame (menu bar and Dock excluded) in AX coordinates.
        var visibleAX: CGRect
        /// The whole display in AX coordinates (to tell which sides touch another display).
        var frameAX: CGRect
        /// The display UUID, as the private Spaces calls name displays.
        var uuid: String
    }

    /// The mouse pointer in AX coordinates.
    static func mouseAX() -> CGPoint? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else { return nil }
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primary.frame.height - p.y)
    }

    /// The screen of a connected display.
    static func screen(of identity: DisplayIdentity) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            let id = CGDirectDisplayID(number.uint32Value)
            return CGDisplayVendorNumber(id) == identity.vendor && CGDisplayModelNumber(id) == identity.model
                && CGDisplaySerialNumber(id) == identity.serial && screen.localizedName == identity.name
        }
    }

    static func connected() -> [Connected] {
        let screens = NSScreen.screens
        // AX coordinates are relative to the primary display, the one whose AppKit origin is 0,0.
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let identity = DisplayIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                           serial: CGDisplaySerialNumber(id), name: screen.localizedName)
            return Connected(identity: identity,
                             visibleAX: axRect(fromAppKit: screen.visibleFrame, primaryHeight: primaryHeight),
                             frameAX: axRect(fromAppKit: screen.frame, primaryHeight: primaryHeight),
                             uuid: CFUUIDCreateString(nil, cfUUID) as String)
        }
    }
}
