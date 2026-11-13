import Foundation

/// The private calls of macOS that Fremspace reaches by name (the raw value is the symbol): macOS
/// has no public way to read which desktop a display shows, which desktop a window is on, or which
/// window an Accessibility element is. They are looked up when the app runs. Bound when the app
/// loads, one that a macOS update removes kept the app from starting at all: no Status page to
/// say so, and no updater to fetch the fix.
public enum PrivateCall: String, CaseIterable {
    case mainConnection = "CGSMainConnectionID"
    case managedDisplaySpaces = "CGSCopyManagedDisplaySpaces"
    case spacesForWindows = "CGSCopySpacesForWindows"
    case windowOfElement = "_AXUIElementGetWindow"
    case processForPID = "GetProcessForPID"
    case dockNotification = "CoreDockSendNotification"
    case keyboardClient = "IOHIDEventSystemClientCreateSimpleClient"
    case keyboardCopyProperty = "IOHIDEventSystemClientCopyProperty"
    case keyboardSetProperty = "IOHIDEventSystemClientSetProperty"

    /// What Fremspace no longer does without it.
    public var loss: PrivateCallLoss {
        switch self {
        case .mainConnection, .managedDisplaySpaces, .spacesForWindows, .windowOfElement: return .placing
        case .processForPID: return .oneWindowForward
        case .dockNotification: return .addingDesktops
        case .keyboardClient, .keyboardCopyProperty, .keyboardSetProperty: return .hyperKey
        }
    }
}

public enum PrivateCallLoss: CaseIterable {
    /// Desktops and windows cannot be read: nothing is placed.
    case placing
    /// A window comes forward with the other windows of its app.
    case oneWindowForward
    /// Mission Control cannot be opened to add desktops.
    case addingDesktops
    /// Caps Lock cannot be made the Hyper key.
    case hyperKey
}

/// Why nothing is applied when a call that placing windows needs is missing, in the words of the
/// engine's status (the menu and the Status page show them); nil when Fremspace can run.
public func missingCallsReason(_ missing: [PrivateCall]) -> String? {
    let needed = PrivateCall.allCases.filter { $0.loss == .placing && missing.contains($0) }
    guard !needed.isEmpty else { return nil }
    return "This macOS lacks a call Fremspace needs (\(needed.map(\.rawValue).joined(separator: ", ")))"
}
