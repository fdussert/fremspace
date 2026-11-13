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
