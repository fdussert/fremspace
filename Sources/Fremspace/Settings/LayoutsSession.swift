import AppKit
import FremspaceCore
import SwiftUI

/// The two views of the Layouts page.
enum LayoutsView: String {
    /// Layouts for one desktop: the ready-made ones, and the desktops kept.
    case oneDesktop
    /// Layout files that hold more: several desktops, displays, drawers, scenes.
    case wholeDesks
}

/// A layout for one desktop: one Fremspace comes with (its id), or one kept in the library (the
/// name of its file).
enum LayoutChoice: Equatable {
    case preset(String)
    case kept(String)
}

/// What a chosen layout makes of a desktop, for the preview and for the action that follows it.
struct LayoutOutcome {
    /// The name of the layout: a ready-made one's, or the desktop's that was kept.
    var name: String
    /// The desktop as it would be.
    var desktop: SpaceSpec
    /// What a ready-made layout did to the slots the desktop had; nil for a kept layout, which
    /// replaces them.
    var reshaped: Reshaped?
    /// The layout as it would arrive on a new desktop.
    var alone: SpaceSpec
    /// The slots the desktop had that are gone.
    var gone: Set<String>
}

extension EditSession {
    /// The layouts of the library that are one desktop, and the others.
    var keptDesktops: [LibraryItem] { library.filter { $0.layout.singleDesktop != nil } }
    var wholeDesks: [LibraryItem] { library.filter { $0.layout.singleDesktop == nil } }

    /// Where a layout chosen on the Layouts page goes: the desktop the editor shows. Nil while that
    /// display is ignored or has no desktop.
    var layoutTarget: (display: DisplaySpec, index: Int, desktop: SpaceSpec)? {
        guard let display = displaySpec, !display.ignored, let desktop = spaceSpec else { return nil }
        return (display, selection.desktop, desktop)
    }

    /// The name of a choice, and the desktop it is when it is a kept one.
    func layoutName(_ choice: LayoutChoice) -> String? {
        switch choice {
        case .preset(let id): return layoutPresets.first { $0.id == id }?.name
        case .kept(let file): return library.first { $0.id == file }?.layout.name
        }
    }

    /// What `choice` would make of `desktop`. A ready-made layout reshapes it and its slots keep
    /// their apps; a kept one replaces its layout and its Focus, and comes with its own apps.
    func layoutOutcome(_ choice: LayoutChoice, on desktop: SpaceSpec, focusOnLargest: Bool) -> LayoutOutcome? {
        switch choice {
        case .preset(let id):
            guard let preset = layoutPresets.first(where: { $0.id == id }) else { return nil }
            let result = reshaped(desktop, to: preset.rects, focusOnLargest: focusOnLargest)
            return LayoutOutcome(name: preset.name, desktop: result.desktop, reshaped: result,
                                 alone: reshaped(SpaceSpec(label: preset.name), to: preset.rects, focusOnLargest: focusOnLargest).desktop,
                                 gone: Set(result.merged))
        case .kept(let file):
            guard let item = library.first(where: { $0.id == file }), let kept = item.layout.singleDesktop else { return nil }
            var replaced = desktop
            replaced.layout = kept.layout
            replaced.focusSlot = kept.focusSlot
            // Every slot it had is gone, the ones whose name the new layout also uses included:
            // a scene that put "main" in Focus meant the slot that was there.
            return LayoutOutcome(name: item.layout.name, desktop: replaced, reshaped: nil, alone: kept,
                                 gone: Set(desktop.layout?.slots.map(\.id) ?? []))
        }
    }

    /// Uses the layout chosen on the desktop the editor shows: one step to undo, nothing moves until
    /// Save, and the editor shows the desktop, on its first slot without an app when it has one.
    func useLayout(_ choice: LayoutChoice, focusOnLargest: Bool) {
        guard let target = layoutTarget, var configuration,
              let outcome = layoutOutcome(choice, on: target.desktop, focusOnLargest: focusOnLargest),
              let d = configuration.displays.firstIndex(where: { $0.identity == target.display.identity }) else { return }
        configuration = forgetting(slots: outcome.gone, ofDesktop: target.index, of: target.display.identity, in: configuration)
        configuration.displays[d].spaces[target.index] = outcome.desktop
        checkpoint()
        updateConfiguration { $0 = configuration }
        show(desktop: target.index)
        let label = target.desktop.label.isEmpty ? "desktop \(target.index + 1)" : "\u{201C}\(target.desktop.label)\u{201D}"
        let empty = outcome.desktop.layout?.slots.filter { $0.rule.bundleID.isEmpty }.count ?? 0
        status = Status(kind: .info, text: "\u{201C}\(outcome.name)\u{201D} is on \(label)."
                        + (empty > 0 ? " Choose the app of its \(counted(empty, "empty slot")), then save." : " Save to apply."))
    }

    /// Adds the layout chosen as a new desktop, after those of the display the editor shows.
    func addLayoutAsDesktop(_ choice: LayoutChoice, focusOnLargest: Bool) {
        guard let target = layoutTarget,
              let outcome = layoutOutcome(choice, on: target.desktop, focusOnLargest: focusOnLargest) else { return }
        checkpoint()
        updateDisplay { $0.spaces.append(outcome.alone) }
        let index = target.display.spaces.count
        show(desktop: index)
        let empty = outcome.alone.layout?.slots.filter { $0.rule.bundleID.isEmpty }.count ?? 0
        status = Status(kind: .info, text: "\u{201C}\(outcome.name)\u{201D} is now desktop \(index + 1) of \(target.display.displayName)."
                        + (empty > 0 ? " Choose the app of its \(counted(empty, "empty slot")), then save." : " Save to apply."))
    }

    /// Back to the editor on a desktop of the display shown, its first slot without an app selected:
    /// that is where the owner goes on, and what Save would point at.
    private func show(desktop index: Int) {
        selection.desktop = index
        selection.drawer = nil
        selection.slot = spaceSpec?.layout?.slots.first { $0.rule.bundleID.isEmpty }?.id
        settingsPage = nil
    }

    /// Keeps the desktop the editor shows among the layouts for one desktop: the same file as a
    /// whole desk's, with that desktop alone. Its drawers are the display's and stay with it.
    func keepShownDesktop() {
        guard let display = displaySpec, let desktop = spaceSpec else { return }
        guard desktop.layout != nil else {
            status = Status(kind: .warning, text: "This desktop is free: it has no layout to keep.")
            return
        }
        let name = desktop.label.isEmpty ? "Desktop \(selection.desktop + 1)" : desktop.label
        let file = sharedDesktop(desktop, named: name, displayName: display.displayName, aspect: displayShapes[display.identity],
                                 withFilters: shareWithFilters)
        guard let kept = keep(file.layout) else { return }
        layoutsView = .oneDesktop
        layoutChoice = .kept(kept)
        let leftOut = file.report.profilesLeftOut + file.report.titleFiltersLeftOut
        status = Status(kind: .success, text: "\u{201C}\(name)\u{201D} is kept in Layouts."
                        + (leftOut > 0 ? " Its browser profiles and title filters are not in the file: the Share page has the tick that keeps them." : ""))
    }
}
