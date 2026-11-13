import Foundation

/// A version of `configuration` for when only `display` is connected (the laptop on the move). That
/// display keeps its desktops and its drawers. Every slot of the other displays becomes a desktop of
/// its own on it, its window filling the screen, in the order of the displays and their desktops; a
/// slot whose apps already have a slot on the display is left out. One free desktop is kept (added
/// when the display has none), so that windows without a slot still have somewhere to go.
/// Nil when `display` is not a display of the configuration, or is ignored.
public func travelConfiguration(from configuration: Configuration, keeping display: DisplayIdentity,
                                id: UUID, name: String) -> Configuration? {
    guard var kept = configuration.displays.first(where: { $0.identity == display && !$0.ignored }) else { return nil }
    // A desktop that sent its other windows to a display that is not there keeps them.
    for index in kept.spaces.indices {
        if case .sendTo = kept.spaces[index].unmatched { kept.spaces[index].unmatched = .float }
    }
    var covered = kept.spaces.flatMap { $0.layout?.slots.flatMap(\.rules) ?? [] }
    var labels = Set(kept.spaces.map(\.label))
    func unique(_ base: String) -> String {
        guard labels.contains(base) else { return base }
        var n = 2
        while labels.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
    for other in configuration.displays where !other.ignored && other.identity != display {
        for space in other.spaces {
            guard let layout = space.layout else { continue }
            for slot in layout.slots where !slot.rules.allSatisfy(covered.contains) {
                var alone = slot
                alone.rect = UnitRect(x: 0, y: 0, w: 1, h: 1)
                let label = unique(layout.slots.count == 1 ? space.label : "\(space.label) · \(slot.id)")
                labels.insert(label)
                covered += slot.rules
                kept.spaces.append(SpaceSpec(label: label, layout: Layout(slots: [alone])))
            }
        }
    }
    if !kept.spaces.contains(where: { $0.layout == nil }) {
        kept.spaces.append(SpaceSpec(label: unique("Free")))
    }
    return Configuration(id: id, name: name, displays: [kept])
}
