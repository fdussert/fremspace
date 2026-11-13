import Foundation

// What the Layouts page says in words: under a drawing, to VoiceOver in place of the drawing, and
// before a layout is used or a file is added. The sentences are rules like the others (which slot
// keeps its app, what is stacked, what is left out), so they are here, where they are tested; the
// app only gives the names of the apps, which it reads from the Mac.

private func counted(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
}

/// The apps of a slot as its tile names them: "Editor + Terminal"; nil for a slot without an app.
private func apps(of slot: Slot, _ appName: (String) -> String) -> String? {
    let names = slot.rules.map(\.bundleID).filter { !$0.isEmpty }.map(appName)
    return names.isEmpty ? nil : names.joined(separator: " + ")
}

private func inReadingOrder(_ slots: [Slot]) -> [Slot] {
    slots.sorted { abs($0.rect.y - $1.rect.y) > 1e-9 ? $0.rect.y < $1.rect.y : $0.rect.x < $1.rect.x }
}

/// Under the drawing of a desktop kept for later: "3 slots, 4 apps, Focus".
public func layoutCounts(_ desktop: SpaceSpec) -> String {
    guard let layout = desktop.layout else { return "free" }
    var parts = [counted(layout.slots.count, "slot")]
    let apps = Set(layout.slots.flatMap(\.rules).map(\.bundleID).filter { !$0.isEmpty }).count
    if apps > 0 { parts.append(counted(apps, "app")) }
    if !focusSlots(desktop).isEmpty { parts.append("Focus") }
    return parts.joined(separator: ", ")
}

/// Under the drawing of a whole desk: "3 displays, 6 desktops, 2 scenes". One display is not said.
public func deskCounts(_ layout: SharedLayout) -> String {
    var parts: [String] = []
    if layout.displays.count > 1 { parts.append(counted(layout.displays.count, "display")) }
    parts.append(counted(layout.displays.reduce(0) { $0 + $1.desktops.count }, "desktop"))
    if !layout.scenes.isEmpty { parts.append(counted(layout.scenes.count, "scene")) }
    return parts.joined(separator: ", ")
}

/// A desktop's slots for who cannot see its drawing, in reading order: "3 slots: Editor (Focus),
/// Terminal, an empty slot". An app of `missing` is said not to be on this Mac.
public func layoutInWords(_ desktop: SpaceSpec, appName: (String) -> String, missing: Set<String> = []) -> String {
    guard let layout = desktop.layout else { return "free: windows float" }
    let focus = Set(focusSlots(desktop).map(\.id))
    let slots = inReadingOrder(layout.slots).map { slot -> String in
        var words = apps(of: slot, appName) ?? "an empty slot"
        if slot.rules.contains(where: { missing.contains($0.bundleID) }) { words += " (not on this Mac)" }
        if focus.contains(slot.id) { words += " (Focus)" }
        return words
    }
    return "\(counted(slots.count, "slot")): \(slots.joined(separator: ", "))"
}

/// What a ready-made layout changes on `desktop`, from what `reshaped` did: which slots keep their
/// apps, which are new and empty, what is stacked and where, where Focus goes, and that the drawers
/// of the display (`drawers` of them) are not part of it.
public func reshapeInWords(_ result: Reshaped, from desktop: SpaceSpec, focusOnLargest: Bool, drawers: Int,
                           appName: (String) -> String) -> [String] {
    let old = desktop.layout?.slots ?? []
    let new = (result.desktop.layout?.slots ?? []).sorted { bySize($0.rect, $1.rect) }
    var sentences: [String] = []
    let kept = new.filter { !result.added.contains($0.id) }.compactMap { apps(of: $0, appName) }
    if desktop.layout == nil {
        sentences.append("It is free now: it gets \(counted(new.count, "empty slot")), and you choose their apps.")
    } else if !result.merged.isEmpty {
        let stacked = old.filter { result.merged.contains($0.id) }.compactMap { apps(of: $0, appName) }
        let host = old.first { $0.id == result.mergedInto }.flatMap { apps(of: $0, appName) }
        var sentence = "Its \(counted(old.count, "slot")) become \(new.count)."
        if stacked.isEmpty {
            sentence += " The ones that go had no app."
        } else if let host {
            sentence += " \(listed(stacked)) \(stacked.count == 1 ? "stacks" : "stack") with \(host) in the smallest slot: nothing you placed is dropped."
        } else {
            sentence += " \(listed(stacked)) \(stacked.count == 1 ? "goes" : "go") to the smallest slot: nothing you placed is dropped."
        }
        sentences.append(sentence)
    } else {
        var sentence = old.count == new.count
            ? "Its \(counted(old.count, "slot")) \(old.count == 1 ? "takes its new shape" : "take these shapes")."
            : "Its \(counted(old.count, "slot")) \(old.count == 1 ? "takes the largest shape" : "take the largest shapes")."
        if !kept.isEmpty {
            sentence += kept.count == 1 ? " \(kept[0]) stays." : " The apps stay, largest slot first: \(kept.joined(separator: ", "))."
        }
        sentences.append(sentence)
        if !result.added.isEmpty {
            sentences.append("\(counted(result.added.count, "new slot")) \(result.added.count == 1 ? "is" : "are") empty: Save waits until \(result.added.count == 1 ? "it has an app" : "they have their apps").")
        }
    }
    let before = Set(focusSlots(desktop).map(\.id)), after = Set(focusSlots(result.desktop).map(\.id))
    if focusOnLargest {
        sentences.append("Focus goes to the largest slot.")
    } else if !before.isEmpty {
        sentences.append(after == before ? "Focus stays where it was."
                         : after.isEmpty ? "Its Focus slot is gone: no slot has Focus." : "Focus stays with the slots that are still there.")
    }
    if drawers > 0 { sentences.append("The \(drawers == 1 ? "drawer of the display is" : "drawers of the display are") not touched.") }
    return sentences
}

/// What a layout kept for later changes on `desktop` when it replaces its layout: the kept slots
/// come with their apps, and the apps the desktop had lose their slot there unless they are among them.
public func replacementInWords(_ kept: SpaceSpec, over desktop: SpaceSpec, drawers: Int, appName: (String) -> String) -> [String] {
    let slots = inReadingOrder(kept.layout?.slots ?? [])
    let coming = slots.compactMap { apps(of: $0, appName) }
    var sentences: [String] = []
    var first = desktop.layout == nil ? "It is free now: it gets \(counted(slots.count, "slot"))"
        : "Its layout is replaced by \(counted(slots.count, "slot"))"
    first += coming.isEmpty ? ", without apps yet." : " with \(slots.count == 1 ? "its app" : "their apps"): \(coming.joined(separator: ", "))."
    sentences.append(first)
    let stay = Set(slots.flatMap(\.rules).map(\.bundleID))
    var leaving: [String] = []
    for id in (desktop.layout?.slots ?? []).flatMap(\.rules).map(\.bundleID) where !id.isEmpty && !stay.contains(id) {
        let name = appName(id)
        if !leaving.contains(name) { leaving.append(name) }
    }
    if !leaving.isEmpty {
        sentences.append("\(listed(leaving)) no longer \(leaving.count == 1 ? "has" : "have") a slot on this desktop.")
    }
    let hadFocus = !focusSlots(desktop).isEmpty
    if let focus = inReadingOrder(focusSlots(kept)).first {
        sentences.append("Focus comes with it\(apps(of: focus, appName).map { ", on \($0)" } ?? "").")
    } else if hadFocus {
        sentences.append("Its Focus goes: the layout has none.")
    }
    if drawers > 0 { sentences.append("The \(drawers == 1 ? "drawer of the display is" : "drawers of the display are") not touched.") }
    return sentences
}

/// A scene of a file as it will be here: "Main shows Code with Focus, Right shows Talk". The
/// displays are called by the names of those that take them (`displayNames`: position in the file,
/// name here); what is on a display left out is not said, and a scene with nothing left is not added.
public func sceneInWords(_ scene: SharedScene, of layout: SharedLayout, displayNames: [Int: String],
                         appName: (String) -> String) -> String {
    var parts: [String] = []
    for desktop in scene.desktops {
        guard let name = displayNames[desktop.display], layout.displays.indices.contains(desktop.display),
              layout.displays[desktop.display].desktops.indices.contains(desktop.index) else { continue }
        let label = layout.displays[desktop.display].desktops[desktop.index].label
        parts.append("\(name) shows \(label)" + (scene.focus.contains { $0.display == desktop.display } ? " with Focus" : ""))
    }
    for drawer in scene.drawers {
        guard let name = displayNames[drawer.display] else { continue }
        parts.append("\(name) \(drawer.open ? "opens" : "closes") its \(drawer.edge.rawValue) drawer")
    }
    guard !parts.isEmpty else { return "Not added: its displays are left out." }
    if !scene.apps.isEmpty { parts.append("opens \(listed(scene.apps.map(appName)))") }
    return parts.joined(separator: ", ")
}

/// What of a file comes with the displays chosen, from the report of adding it: "5 of its 6
/// desktops, 2 scenes".
public func importInWords(_ report: ImportReport, of layout: SharedLayout) -> String {
    let desktops = layout.displays.reduce(0) { $0 + $1.desktops.count }
    guard report.desktops > 0 else { return "Nothing yet: choose a display for one of its rows." }
    var parts = [report.desktops == desktops ? "Its \(counted(desktops, "desktop"))" : "\(report.desktops) of its \(counted(desktops, "desktop"))"]
    if !layout.scenes.isEmpty {
        parts.append(report.scenes == layout.scenes.count ? counted(report.scenes, "scene")
                     : "\(report.scenes) of its \(counted(layout.scenes.count, "scene"))")
    }
    if report.drawers > 0 { parts.append(counted(report.drawers, "drawer")) }
    return parts.joined(separator: ", ")
}

/// The warning under a display of a file that goes on a display of the other shape; nil when they fit.
public func shapeFitInWords(_ fit: DisplayShapeFit) -> String? {
    switch fit {
    case .fits: return nil
    case .madeForTall: return "Made for a tall display: yours is wide, the rows will be flat."
    case .madeForWide: return "Made for a wide display: yours is tall, the columns will be narrow."
    }
}
