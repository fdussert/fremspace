import Foundation

/// How a call window is told from the app's other windows.
public enum CallMarker: Equatable {
    /// The DOM identifier of a control only a running call shows (read through Accessibility).
    case control(String)
    /// The app opens a window for the call, whose title starts with one of these.
    case titlePrefix([String])
}

/// The marker of an app's call windows; nil for apps whose calls Fremspace does not know.
///
/// Microsoft Teams (checked live, 2026-11-10): the meeting window is titled "Meeting join | <name>"
/// before joining and "<name>" once in the call, so the title does not tell; the "Leave" button
/// (`hangup-button`) is there only during the call.
///
/// Zoom (from the strings of Zoom 7.1.9, not checked in a live meeting): the meeting window is
/// titled "Zoom Meeting" ("Réunion Zoom" in French), a webinar "Zoom Webinar" ("Webinaire Zoom");
/// the main window is "Zoom Workplace". Other languages are to add here.
public func callWindowMarker(bundleID: String) -> CallMarker? {
    switch bundleID {
    case "com.microsoft.teams2": return .control("hangup-button")
    case "us.zoom.xos": return .titlePrefix(["Zoom Meeting", "Réunion Zoom", "Zoom Webinar", "Webinaire Zoom"])
    default: return nil
    }
}

/// Whether `title` is a call window's, for a marker that the title answers; nil when the window's
/// content has to be looked at.
public func isCallWindow(title: String, marker: CallMarker) -> Bool? {
    switch marker {
    case .control: return nil
    case .titlePrefix(let prefixes): return prefixes.contains { title.hasPrefix($0) }
    }
}

/// The apps whose call window Fremspace knows, with the name the settings show.
public let callApps: [(bundleID: String, name: String)] = [
    ("com.microsoft.teams2", "Microsoft Teams"),
    ("us.zoom.xos", "Zoom"),
]

/// Whether the calls of `bundleID` go to full screen: Fremspace knows its call window and the owner
/// turned it on in the general settings.
public func wantsFullScreenCalls(bundleID: String, in config: Config) -> Bool {
    callWindowMarker(bundleID: bundleID) != nil && config.fullScreenCalls.contains(bundleID)
}
