#if FREMSPACE_SPARKLE
import AppKit
import Sparkle

/// Sparkle, in the distributed app only: a release build (`FREMSPACE_SPARKLE=1 scripts/build.sh`,
/// which is what `scripts/release.sh` runs) compiles this file with `-D FREMSPACE_SPARKLE` and
/// embeds the framework. The everyday build has neither: no dependency to fetch, and a build from
/// a checkout never replaces itself with a release.
///
/// The feed and the public EdDSA key are in the app's Info.plist (`SUFeedURL`, `SUPublicEDKey`).
/// The only request is for the feed, a file on GitHub; nothing about the Mac is sent (Sparkle's
/// system profile is off unless asked for, and it is not).
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// "Check for Updates…": the owner asked, so the window comes to the front.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    // A menu bar app has no window to come back to, and a scheduled check that pulled the app to
    // the front would take the keyboard from whatever the owner is typing in. Gentle reminders let
    // Sparkle show a found update without activating the app.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
#endif
