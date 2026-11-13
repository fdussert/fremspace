import CoreGraphics
import Foundation

/// A desktop of a configuration: a display and the position of the desktop in its configured list.
public struct ConfiguredDesktop: Codable, Hashable {
    public var display: DisplayIdentity
    public var index: Int

    public init(display: DisplayIdentity, index: Int) {
        self.display = display
        self.index = index
    }
}

/// Where one window was last seen in a configuration: its desktop, its slot when it had one, its
/// frame.
public struct RememberedPlacement: Codable, Equatable {
    public var identity: WindowIdentity
    public var windowID: UInt32
    public var configurationID: UUID
    public var desktop: ConfiguredDesktop
    public var slotID: String?
    public var frame: CGRect
    public var lastSeen: Date

    public init(identity: WindowIdentity, windowID: UInt32, configurationID: UUID, desktop: ConfiguredDesktop,
                slotID: String?, frame: CGRect, lastSeen: Date) {
        self.identity = identity
        self.windowID = windowID
        self.configurationID = configurationID
        self.desktop = desktop
        self.slotID = slotID
        self.frame = frame
        self.lastSeen = lastSeen
    }
}

/// Where each window belongs, kept across relaunches and reboots in `state.json`.
public struct Remembered: Codable, Equatable {
    public var entries: [RememberedPlacement]

    public init(entries: [RememberedPlacement] = []) {
        self.entries = entries
    }

    /// Replaces the entry of the same window in the same configuration. Window ids start again
    /// after a reboot: an entry last seen before `idsSince` (the boot) belongs to another window and
    /// is kept.
    public mutating func record(_ placement: RememberedPlacement, idsSince: Date = .distantPast) {
        entries.removeAll {
            $0.windowID == placement.windowID && $0.configurationID == placement.configurationID && $0.lastSeen >= idsSince
        }
        entries.append(placement)
    }

    /// The entry of a live window (seen since `idsSince`), in `configurationID` when given.
    public func entry(forWindow id: UInt32, configurationID: UUID? = nil, idsSince: Date = .distantPast) -> RememberedPlacement? {
        entries.last {
            $0.windowID == id && $0.lastSeen >= idsSince && (configurationID == nil || $0.configurationID == configurationID)
        }
    }

    /// Whether a window may be recorded where it is now: only once the router compared it with the
    /// remembered windows of its app (else, after a reboot, its new place would be recorded under
    /// its new id and win over the place it had).
    public func mayRecord(bundleID: String, configurationID: UUID, recognised: Bool) -> Bool {
        recognised || !entries.contains { $0.identity.bundleID == bundleID && $0.configurationID == configurationID }
    }

    /// Configured desktop `index` of a display was removed (editor): its entries go, the next
    /// desktops' entries move up.
    public mutating func removeDesktop(configuration: UUID, display: DisplayIdentity, index: Int) {
        entries.removeAll { $0.configurationID == configuration && $0.desktop.display == display && $0.desktop.index == index }
        for i in entries.indices
        where entries[i].configurationID == configuration && entries[i].desktop.display == display && entries[i].desktop.index > index {
            entries[i].desktop.index -= 1
        }
    }

    /// Configured desktop `from` of a display was moved to position `to` (editor): its entries follow
    /// it, those of the desktops in between shift by one.
    public mutating func moveDesktop(configuration: UUID, display: DisplayIdentity, from: Int, to: Int) {
        guard from != to else { return }
        for i in entries.indices where entries[i].configurationID == configuration && entries[i].desktop.display == display {
            entries[i].desktop.index = movedIndex(entries[i].desktop.index, from: from, to: to)
        }
    }

    /// The remembered placement of each live window of configuration `configurationID`: by window id
    /// first (same app; only for entries seen since `idsSince`, the system boot, because window ids
    /// start again after a reboot), then by identity among the rest.
    public func match(live: [UInt32: WindowIdentity], configurationID: UUID,
                      idsSince: Date = .distantPast) -> [UInt32: RememberedPlacement] {
        let candidates = entries.filter { $0.configurationID == configurationID }
        var result: [UInt32: RememberedPlacement] = [:]
        var used: Set<Int> = []
        for (id, identity) in live {
            guard let index = candidates.lastIndex(where: {
                $0.windowID == id && $0.lastSeen >= idsSince && $0.identity.bundleID == identity.bundleID
            }) else { continue }
            result[id] = candidates[index]
            used.insert(index)
        }
        let restLive = live.filter { result[$0.key] == nil }
        let restIndices = candidates.indices.filter { !used.contains($0) }
        let matched = matchIdentities(live: restLive, remembered: restIndices.map { candidates[$0].identity })
        for (id, position) in matched {
            result[id] = candidates[restIndices[position]]
        }
        return result
    }

    /// `entry` now belongs to live window `id` (recognised after a relaunch): re-keyed, so that the
    /// next `record` for that window replaces it instead of adding a second entry.
    public mutating func adopt(_ entry: RememberedPlacement, as id: UInt32, idsSince: Date = .distantPast, now: Date = Date()) {
        guard let index = entries.firstIndex(of: entry) else { return }
        var adopted = entry
        adopted.windowID = id
        // Seen now under its new id: the next record of this window replaces it.
        adopted.lastSeen = max(entry.lastSeen, now)
        entries[index] = adopted
        entries.removeAll {
            $0.windowID == id && $0.configurationID == adopted.configurationID && $0.lastSeen >= idsSince && $0 != adopted
        }
    }

    /// How long a window that did not come back stays remembered.
    public static let maxAge: TimeInterval = 90 * 24 * 3600

    /// Keeps the `keep` most recently seen entries, and forgets the windows of an earlier session
    /// (last seen before `idsSince`, the boot or the login) that were not seen for `maxAge`: an
    /// entry holds a title, the titles of a browser's tabs and a document's address, which must
    /// not stay in a file for ever after the window is closed. A window of this session is never
    /// forgotten for its age: its entry is written again only when something about it changes,
    /// so a window left alone for months still has the date of its last change.
    public mutating func prune(keep: Int = 300, now: Date = Date(), idsSince: Date = .distantPast,
                               maxAge: TimeInterval = Remembered.maxAge) {
        let oldest = now.addingTimeInterval(-maxAge)
        entries.removeAll { $0.lastSeen < idsSince && $0.lastSeen < oldest }
        guard entries.count > keep else { return }
        entries = Array(entries.sorted { $0.lastSeen > $1.lastSeen }.prefix(keep))
    }
}

/// Where position `index` of a list ends up when the element at `from` is moved to `to`.
public func movedIndex(_ index: Int, from: Int, to: Int) -> Int {
    if index == from { return to }
    if from < to, index > from, index <= to { return index - 1 }
    if from > to, index >= to, index < from { return index + 1 }
    return index
}
