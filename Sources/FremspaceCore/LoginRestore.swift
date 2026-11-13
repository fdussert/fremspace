import Foundation

/// Fremspace started at login (its first start in a login session) rather than relaunched later.
public func isLoginStart(appStart: Date, sessionStart: Date, within: TimeInterval = 180) -> Bool {
    let delay = appStart.timeIntervalSince(sessionStart)
    return delay >= 0 && delay <= within
}

/// The apps to launch at login: those with a slot whose `launchAtLogin` is on, on displays that are
/// not ignored, not running yet. Each once (Brave is one process for every profile), in
/// configuration order.
public func appsToLaunch(configuration: Configuration, running: Set<String>) -> [String] {
    var result: [String] = []
    for display in configuration.displays where !display.ignored {
        for space in display.spaces {
            for slot in space.layout?.slots ?? [] where slot.launchAtLogin {
                for app in slot.rules.map(\.bundleID) where !running.contains(app) && !result.contains(app) {
                    result.append(app)
                }
            }
        }
    }
    return result
}

/// Apps launched at login that showed no window in time: given up and reported.
public struct LaunchTracker {
    private var launches: [String: Date] = [:]

    public init() {}

    public mutating func launched(_ bundleID: String, at date: Date) {
        launches[bundleID] = date
    }

    public mutating func sawWindow(_ bundleID: String) {
        launches[bundleID] = nil
    }

    /// Apps still without a window `timeout` seconds after their launch.
    public func overdue(now: Date, timeout: TimeInterval = 30) -> [String] {
        launches.filter { now.timeIntervalSince($0.value) > timeout }.map(\.key).sorted()
    }
}
