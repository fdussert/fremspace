import Foundation

/// The app's updater, as the menu and the General page see it. A build from a checkout has none
/// (`isAvailable` is false, and neither shows anything about updates): it must never replace
/// itself with a release. The distributed app fills this in from Sparkle (Updater.swift).
final class Updates {
    /// "Check for Updates…". Nil without an updater.
    var check: (() -> Void)?
    /// Whether the app looks for a newer version by itself, about once a day.
    var automaticChecks: () -> Bool = { false }
    var setAutomaticChecks: (Bool) -> Void = { _ in }

    var isAvailable: Bool { check != nil }
}
