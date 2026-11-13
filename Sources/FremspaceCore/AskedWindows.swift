import Foundation

/// The windows Fremspace itself asks another app for: a folder shown in the Finder from the editor,
/// the config file opened from the menu. Such a window was asked for where the owner is, and with
/// "no floating windows" it must not be sent to a free desktop behind the window that asked for it
/// (owner, 2026-11-13: the Layouts folder opened from the editor went to another desktop).
public struct AskedWindows {
    /// How long after the request the app's next new window is taken for the one asked for.
    public static let wait: TimeInterval = 5

    private var asked: [String: (until: Date, existing: Set<UInt32>)] = [:]

    public init() {}

    /// Fremspace is about to ask `bundleID` for a window; `existing` are the windows the app has
    /// now, which are not the one asked for.
    public mutating func expect(_ bundleID: String, existing: Set<UInt32>, now: Date) {
        asked[bundleID] = (now.addingTimeInterval(Self.wait), existing)
    }

    /// Whether window `id` of `bundleID`, first looked at at `now`, is the one asked for. Once per
    /// request: the window the owner opens next is an ordinary one.
    public mutating func take(_ id: UInt32, bundleID: String, now: Date) -> Bool {
        guard let request = asked[bundleID] else { return false }
        guard now < request.until else {
            asked[bundleID] = nil
            return false
        }
        guard !request.existing.contains(id) else { return false }
        asked[bundleID] = nil
        return true
    }
}
