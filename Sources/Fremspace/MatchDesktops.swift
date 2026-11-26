import AppKit
import FremspaceCore

/// "Give the Mac the desktops of the configuration", asked from the editor, the palette or a
/// shortcut: what it would do is said first, and the owner says yes before a desktop is removed.
extension Engine {
    /// What matching would do now, per display in the order of the configuration, with the
    /// display's name.
    var desktopsToMatchByName: [(display: String, plan: DesktopsToMatch)] {
        guard let configuration = activeConfiguration else { return [] }
        let plans = desktopsToMatch()
        return configuration.displays.compactMap { spec in
            plans[spec.identity].map { (configuration.displayName(spec.identity), $0) }
        }
    }

    /// Matches the Mac to the configuration in use, after a question when desktops would be
    /// removed: macOS moves their windows to another desktop and nothing undoes it. Adding alone
    /// asks nothing, as "Add the missing desktops" never did. nil when there is nothing to do, or
    /// when the owner said no.
    func matchDesktopsAfterAsking() -> DesktopsMatched? {
        let said = matchSentences(desktopsToMatchByName)
        guard said.add != nil || said.remove != nil else { return nil }
        if let removes = said.remove {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Give this Mac the desktops of \u{201C}\(activeConfiguration?.name ?? "")\u{201D}?"
            alert.informativeText = [said.add, "\(removes) macOS moves the windows that are on them to another desktop, and this cannot be undone.",
                                     "Mission Control opens for a moment."].compactMap { $0 }.joined(separator: " ")
            alert.addButton(withTitle: said.add == nil ? "Remove" : "Add and remove").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            // Asked from a shortcut, Fremspace is not the app in front.
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        return matchDesktops()
    }
}

extension Engine.DesktopsMatched {
    /// "4 desktops added, 4 removed."
    var said: String {
        let parts = [added > 0 ? "\(added) desktop\(added == 1 ? "" : "s") added" : nil,
                     removed > 0 ? "\(removed) \(added > 0 ? "" : removed == 1 ? "desktop " : "desktops ")removed" : nil].compactMap { $0 }
        return parts.isEmpty ? "Nothing changed." : parts.joined(separator: ", ") + "."
    }

    /// What to do by hand when Mission Control did not let everything be done.
    static let byHand = "In Mission Control, the + at the top right of a display adds a desktop, and the \u{2715} of a desktop removes it."
}
