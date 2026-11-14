import AppKit
import FremspaceCore
import ServiceManagement

/// Restore at login (spec Part A): every window back where it was remembered, and the apps with a
/// slot that are not running launched, then sent to their desktop. "At login" is Fremspace's first
/// start in a login session; "Restore everything now" runs the same pass on demand.
final class LoginRestorer {
    /// Windows that appear this long after a restore starts are routed as restored ones.
    static let restoreWindow: TimeInterval = 60
    static let checkInterval: TimeInterval = 5

    private unowned let engine: Engine
    private let windows: AXWindows
    private var tracker = LaunchTracker()
    private var launched: [String] = []
    /// Apps launched at login that showed no window within 30 s.
    private(set) var didNotStart: [String] = []

    init(engine: Engine, windows: AXWindows) {
        self.engine = engine
        self.windows = windows
    }

    /// At startup: the login pass when this is the session's first start, else the startup pass.
    func startup() {
        if let session = Self.sessionStart(), isLoginStart(appStart: Self.processStart() ?? Date(), sessionStart: session) {
            Log.engine.notice("first start in this login session: restoring every window")
            restoreNow()
        } else {
            engine.router.sortAll(reason: .startup)
        }
    }

    /// Puts every window back where it was remembered and launches the missing apps.
    func restoreNow() {
        guard engine.mayRoute, let configuration = engine.activeConfiguration else { return }
        engine.router.restoring(until: Date().addingTimeInterval(Self.restoreWindow))
        engine.appsAreStarting(until: Date().addingTimeInterval(Self.restoreWindow))
        engine.router.sortAll(reason: .login)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        launched = appsToLaunch(configuration: configuration, running: running)
        didNotStart = []
        tracker = LaunchTracker()
        for bundleID in launched {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                Log.engine.error("cannot launch \(bundleID, privacy: .public): not installed")
                didNotStart.append(bundleID)
                continue
            }
            tracker.launched(bundleID, at: Date())
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: options) { _, error in
                if let error {
                    Log.engine.error("launching \(bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            Log.engine.notice("launched \(bundleID, privacy: .public) at login")
        }
        if !launched.isEmpty { checkLaunches(until: Date().addingTimeInterval(35)) }
    }

    /// Notes which launched apps showed a window; those without one 30 s after their launch are
    /// given up and listed in the menu.
    private func checkLaunches(until deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkInterval) { [weak self] in
            guard let self else { return }
            for bundleID in self.launched {
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                if apps.contains(where: { !self.windows.windowElements(pid: $0.processIdentifier).isEmpty }) {
                    self.tracker.sawWindow(bundleID)
                }
            }
            for bundleID in self.tracker.overdue(now: Date()) where !self.didNotStart.contains(bundleID) {
                self.didNotStart.append(bundleID)
                self.tracker.sawWindow(bundleID)
                Log.engine.error("\(bundleID, privacy: .public) did not show a window within 30 s of its launch")
            }
            if Date() < deadline { self.checkLaunches(until: deadline) }
        }
    }

    // MARK: - Open at login

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("open at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Times

    /// When the owner logged in: the console entry of the login records.
    static func sessionStart() -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let entry = getutxent() {
            var record = entry.pointee
            guard record.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: &record.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let user = withUnsafeBytes(of: &record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", user == NSUserName() else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(record.ut_tv.tv_sec))
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest
    }

    /// When this process started.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
