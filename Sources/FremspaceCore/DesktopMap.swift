import Foundation

/// Which macOS desktop (by uuid) each configured desktop is, per configuration and display. macOS
/// reorders desktops ("Automatically rearrange Spaces", `killall Dock`, a desktop added in the
/// middle); a uuid stays with its desktop.
public struct DesktopLinks: Codable, Equatable {
    /// `key(configuration:display:)` → the linked uuid of each configured desktop, nil when unlinked.
    public var links: [String: [String?]]

    public init(links: [String: [String?]] = [:]) {
        self.links = links
    }

    public static func key(configuration: UUID, display: DisplayIdentity) -> String {
        "\(configuration.uuidString)|\(display.vendor)-\(display.model)-\(display.serial)"
    }

    /// Configured desktop `index` was removed (editor): its link goes, the next ones move up.
    public mutating func removeDesktop(configuration: UUID, display: DisplayIdentity, index: Int) {
        let key = Self.key(configuration: configuration, display: display)
        guard var list = links[key], list.indices.contains(index) else { return }
        list.remove(at: index)
        links[key] = list
    }

    /// A desktop was added at configured position `index` (editor) on the macOS desktop `uuid`: the
    /// links of the desktops from there on move down, each with its own.
    public mutating func insertDesktop(configuration: UUID, display: DisplayIdentity, index: Int, uuid: String) {
        let key = Self.key(configuration: configuration, display: display)
        var list = links[key] ?? []
        if list.count < index { list += Array(repeating: nil, count: index - list.count) }
        list.insert(uuid, at: max(0, index))
        links[key] = list
    }

    /// Ties configured desktop `configured` to `uuid`; the uuid leaves any other configured desktop
    /// of the same display.
    public mutating func link(configuration: UUID, display: DisplayIdentity, configured: Int, to uuid: String) {
        let key = Self.key(configuration: configuration, display: display)
        var list = links[key] ?? []
        for i in list.indices where list[i] == uuid { list[i] = nil }
        if list.count <= configured { list += Array(repeating: nil, count: configured + 1 - list.count) }
        list[configured] = uuid
        links[key] = list
    }
}

/// The real position of each configured desktop. Linked desktops follow their uuid; a linked uuid
/// that is gone maps to nothing (its neighbour does not take its place). Unlinked desktops take
/// their own position when it is free and its uuid is not linked elsewhere, and get linked to it
/// (an empty uuid stays position-based). The first desktop of the main display has no uuid, so it
/// can never be linked: when another desktop was moved to its position in Mission Control, the
/// unlinked configured desktop that found its place taken follows it to the position that has no
/// uuid, instead of resolving to nothing.
///
/// An unlinked desktop that still has no place takes the first desktop nothing else uses, and is
/// linked to it. That is a desktop just added to a configuration whose display has a spare one
/// before the end: one removed from the middle of the configuration leaves its macOS desktop
/// there, and the new layout applied nowhere, with no desktop short to say so.
public func resolveDesktops(configured: Int, links: [String?], live: [String]) -> (real: [Int?], links: [String?]) {
    var newLinks = Array(links.prefix(configured))
    newLinks += Array(repeating: nil, count: configured - newLinks.count)
    var real: [Int?] = Array(repeating: nil, count: configured)
    var used: Set<Int> = []
    for i in 0..<configured {
        guard let uuid = newLinks[i], !uuid.isEmpty, let position = live.firstIndex(of: uuid) else { continue }
        real[i] = position
        used.insert(position)
    }
    let linked = Set(newLinks.compactMap { $0 })
    for i in 0..<configured where real[i] == nil && newLinks[i] == nil {
        guard i < live.count, !used.contains(i), !linked.contains(live[i]) || live[i].isEmpty else { continue }
        real[i] = i
        used.insert(i)
        if !live[i].isEmpty { newLinks[i] = live[i] }
    }
    for i in 0..<configured where real[i] == nil && newLinks[i] == nil {
        // The desktop without a uuid first: an unlinked desktop may be the one that was on it.
        if i < live.count, used.contains(i),
           let position = live.indices.first(where: { live[$0].isEmpty && !used.contains($0) }) {
            real[i] = position
            used.insert(position)
            continue
        }
        guard let position = live.indices.first(where: {
            !live[$0].isEmpty && !used.contains($0) && !linked.contains(live[$0])
        }) else { continue }
        real[i] = position
        used.insert(position)
        newLinks[i] = live[position]
    }
    return (real, newLinks)
}

/// The links once the configured desktops that have no macOS desktop take, in order, the macOS
/// desktops nothing uses: the first homeless one the first spare one, and so on. `count` is how
/// many found a place, `even` whether there were exactly as many of one as of the other. nil when
/// no desktop is homeless, or none is spare.
///
/// `resolveDesktops` never does this by itself: a desktop whose own is gone is looked for, not
/// replaced, so that a desktop missing for a moment does not lose its layout to a neighbour. But
/// macOS makes desktops anew when a display leaves or comes back (owner, 2026-11-24: back on the
/// laptop alone, five of its nine desktops had new uuids; five layouts had no desktop, five
/// desktops no layout, and "restore everything" restored nothing). It is done when the displays
/// have just changed and the two counts are the same, and when the owner asks for everything to
/// be put back.
public func adoptedLinks(configured: Int, links: [String?], live: [String]) -> (links: [String?], count: Int, even: Bool)? {
    let resolved = resolveDesktops(configured: configured, links: links, live: live)
    let homeless = (0..<configured).filter { resolved.real[$0] == nil }
    let used = Set(resolved.real.compactMap { $0 })
    // The desktop without a uuid cannot be linked: it is found by its position alone.
    let spare = live.indices.filter { !used.contains($0) && !live[$0].isEmpty }
    guard !homeless.isEmpty, !spare.isEmpty else { return nil }
    var next = resolved.links
    for (index, position) in zip(homeless, spare) { next[index] = live[position] }
    return (next, min(homeless.count, spare.count), homeless.count == spare.count)
}

/// What it takes for a display to have the desktops its configuration lists, and no other.
public struct DesktopsToMatch: Equatable {
    /// How many desktops the display lacks.
    public var add: Int
    /// The real positions, in Mission Control order, of the desktops no layout would use.
    public var remove: [Int]

    public var isEmpty: Bool { add == 0 && remove.isEmpty }

    public init(add: Int = 0, remove: [Int] = []) {
        self.add = add
        self.remove = remove
    }
}

/// What to add to a display, or to remove from it, for its desktops to be the configured ones. The
/// layouts whose macOS desktop is gone first take the desktops nothing uses, in order
/// (`adoptedLinks`): what is still without a desktop after that is to add, what is still unused is
/// to remove. Never both, and never the desktop without a uuid: nothing could check afterwards
/// that it is the one that went.
///
/// Switching between a desk and the laptop alone leaves this to do every time: macOS keeps the
/// desktops of the configuration that was in use and gives a display that comes back one desktop
/// (owner, 2026-11-26: four to remove one by one on a display, five to add on two others).
public func desktopsToMatch(configured: Int, links: [String?], live: [String]) -> DesktopsToMatch {
    let adopted = adoptedLinks(configured: configured, links: links, live: live)?.links ?? links
    let resolved = resolveDesktops(configured: configured, links: adopted, live: live)
    let homeless = resolved.real.filter { $0 == nil }.count
    guard homeless == 0 else { return DesktopsToMatch(add: homeless) }
    let used = Set(resolved.real.compactMap { $0 })
    // macOS keeps one desktop per display: a configuration that lists none leaves them all.
    guard !used.isEmpty else { return DesktopsToMatch() }
    return DesktopsToMatch(remove: live.indices.filter { !used.contains($0) && !live[$0].isEmpty })
}

/// What matching does, said to the owner before it is done: one sentence for what is added, one
/// for what is removed ("Adds 4 desktops to Main and 1 desktop to Right.", "Removes Desktops 5,
/// 6 and 7 of Laptop."), nil when there is nothing of the kind. `plans`: each display by its name,
/// in the order of the configuration.
public func matchSentences(_ plans: [(display: String, plan: DesktopsToMatch)]) -> (add: String?, remove: String?) {
    func listed(_ words: [String]) -> String {
        words.count < 2 ? words.joined() : words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
    }
    let adds = plans.filter { $0.plan.add > 0 }.map {
        "\($0.plan.add) desktop\($0.plan.add == 1 ? "" : "s") to \($0.display)"
    }
    let removes = plans.filter { !$0.plan.remove.isEmpty }.map {
        "Desktop\($0.plan.remove.count == 1 ? "" : "s") \(listed($0.plan.remove.map { String($0 + 1) })) of \($0.display)"
    }
    return (adds.isEmpty ? nil : "Adds \(listed(adds)).", removes.isEmpty ? nil : "Removes \(listed(removes)).")
}

/// Links that put the configured desktops of a display in Mission Control's order, over the macOS
/// desktops they use now: the first configured desktop on the first of those, and so on. nil when
/// they already go that way, and when it cannot be done for sure: a configured desktop without a
/// real one, or the desktop without a uuid, which cannot be linked, out of the place it would get.
public func alignedLinks(configured: Int, links: [String?], live: [String]) -> [String?]? {
    let now = resolveDesktops(configured: configured, links: links, live: live).real
    let positions = now.compactMap { $0 }
    guard positions.count == configured else { return nil }
    let used = positions.sorted()
    guard used != positions else { return nil }
    let aligned: [String?] = used.map { live[$0].isEmpty ? nil : live[$0] }
    guard resolveDesktops(configured: configured, links: aligned, live: live).real == used.map(Optional.some) else { return nil }
    return aligned
}

/// Configured ↔ real desktop positions of the active configuration, for the connected displays.
public struct DesktopMap: Equatable {
    private var real: [DisplayIdentity: [Int?]] = [:]

    public init() {}

    /// Resolves every display of `configuration` present in `live` (display → uuids of its desktops,
    /// in order) and records new links in `links`.
    public init(configuration: Configuration, live: [DisplayIdentity: [String]], links: inout DesktopLinks) {
        for display in configuration.displays {
            guard let uuids = live[display.identity] else { continue }
            let key = DesktopLinks.key(configuration: configuration.id, display: display.identity)
            let resolved = resolveDesktops(configured: display.spaces.count, links: links.links[key] ?? [], live: uuids)
            real[display.identity] = resolved.real
            if resolved.links.contains(where: { $0 != nil }) || links.links[key] != nil {
                links.links[key] = resolved.links
            }
        }
    }

    /// The configured desktop at real position `real`, nil when none is.
    public func configured(_ display: DisplayIdentity, real position: Int) -> Int? {
        real[display]?.firstIndex(where: { $0 == position })
    }

    /// The real positions of `display`, among its `count` desktops, that hold no configured desktop:
    /// what macOS has and the configuration does not list. Empty for a display the map does not
    /// know, and while a configured desktop has no real one: then a desktop is being looked for,
    /// and one that looks spare may be the one.
    public func unconfigured(_ display: DisplayIdentity, live count: Int) -> [Int] {
        guard let list = real[display], !list.contains(where: { $0 == nil }) else { return [] }
        let taken = Set(list.compactMap { $0 })
        return (0..<max(0, count)).filter { !taken.contains($0) }
    }

    /// How many configured desktops of `display` come before real position `position`: where a
    /// desktop that takes it sits among them, for the tabs to go as Mission Control does.
    public func rank(_ display: DisplayIdentity, real position: Int) -> Int {
        (real[display] ?? []).compactMap { $0 }.filter { $0 < position }.count
    }

    /// The configured desktops of `display` in the order Mission Control shows them, when that is
    /// not the order of the configuration; nil when it is, or while one of them has no real desktop.
    public func missionControlOrder(_ display: DisplayIdentity) -> [Int]? {
        guard let list = real[display], !list.contains(where: { $0 == nil }) else { return nil }
        let positions = list.compactMap { $0 }
        let order = positions.indices.sorted { positions[$0] < positions[$1] }
        return order == Array(positions.indices) ? nil : order
    }

    /// The real position of configured desktop `configured`, nil when it is not there.
    public func real(_ display: DisplayIdentity, configured: Int) -> Int? {
        guard let list = real[display], configured < list.count else { return nil }
        return list[configured]
    }
}

/// The number in what Mission Control calls a desktop ("Desktop 4", "Bureau 4"): its last run of
/// digits. nil when it has none.
public func desktopNumber(inTitle title: String) -> Int? {
    var digits = ""
    for character in title.reversed() {
        if character.isASCII, character.isNumber {
            digits.insert(character, at: digits.startIndex)
        } else if !digits.isEmpty {
            break
        }
    }
    return Int(digits)
}
