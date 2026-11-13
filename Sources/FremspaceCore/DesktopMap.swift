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
/// (an empty uuid stays position-based).
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

    /// The real position of configured desktop `configured`, nil when it is not there.
    public func real(_ display: DisplayIdentity, configured: Int) -> Int? {
        guard let list = real[display], configured < list.count else { return nil }
        return list[configured]
    }
}
