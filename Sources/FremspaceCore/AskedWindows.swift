import Foundation

/// The windows Fremspace itself asks another app for: a folder shown in the Finder from the editor,
/// the config file opened from the menu. Such a window was asked for where the owner is, and with
/// "no floating windows" it must not be sent to a free desktop behind the window that asked for it
/// (owner, 2026-11-13: the Layouts folder opened from the editor went to another desktop).
public struct AskedWindows {
    /// How long after the request the app's next new window is taken for the one asked for.
    public static let wait: TimeInterval = 5

    private var asked: [String: (until: Date, existing: Set<UInt32>)] = [:]

    public init() {}

    /// Fremspace is about to ask `bundleID` for a window; `existing` are the windows the app has
    /// now, which are not the one asked for.
    public mutating func expect(_ bundleID: String, existing: Set<UInt32>, now: Date) {
        asked[bundleID] = (now.addingTimeInterval(Self.wait), existing)
    }

    /// Whether window `id` of `bundleID`, first looked at at `now`, is the one asked for. Once per
    /// request: the window the owner opens next is an ordinary one.
    public mutating func take(_ id: UInt32, bundleID: String, now: Date) -> Bool {
        guard let request = asked[bundleID] else { return false }
        guard now < request.until else {
            asked[bundleID] = nil
            return false
        }
        guard !request.existing.contains(id) else { return false }
        asked[bundleID] = nil
        return true
    }
}

/// Whether a window shows the file or folder at `url`: by the address Accessibility gives for its
/// document ("file:///…/Layouts/"), which settles it either way; without one, and only where the
/// title of a window is the name of what it shows (`byTitle`: the Finder), by its title.
public func windowShows(_ url: URL, document: String?, title: String?, byTitle: Bool) -> Bool {
    if let document, let shown = URL(string: document), shown.isFileURL {
        return shown.standardizedFileURL.path == url.standardizedFileURL.path
    }
    return byTitle && title == url.lastPathComponent
}

/// Where the window of a folder a slot asked for goes.
public enum FolderTarget: Equatable {
    /// A slot of the layout of a desktop.
    case slot(ConfiguredDesktop, String)
    /// A slot of a drawer of a display, by its key (`"<edge>.<slot id>"`).
    case drawer(DisplayIdentity, String)

    /// The slot's name, for the log (a folder's path never goes there).
    public var name: String {
        switch self {
        case .slot(_, let id): return id
        case .drawer(_, let key): return key
        }
    }
}

/// A folder a slot asks for: where it is, the app to open it in, and the slot its window goes to.
public struct FolderToOpen: Equatable {
    public var folder: String
    public var bundleID: String
    public var target: FolderTarget

    public init(folder: String, bundleID: String, target: FolderTarget) {
        self.folder = folder
        self.bundleID = bundleID
        self.target = target
    }
}

/// The folders the slots of `configuration` ask for, in the order of the file: the layouts of the
/// displays Fremspace arranges, then their drawers. A folder asked for twice in one app is opened
/// once, for the first slot that asks: one window cannot be in two slots.
public func foldersToOpen(_ configuration: Configuration) -> [FolderToOpen] {
    var result: [FolderToOpen] = []
    func add(_ rules: [Rule], _ target: FolderTarget) {
        for rule in rules {
            guard let folder = rule.folder?.trimmingCharacters(in: .whitespaces), !folder.isEmpty, !rule.bundleID.isEmpty,
                  !result.contains(where: { $0.folder == folder && $0.bundleID == rule.bundleID }) else { continue }
            result.append(FolderToOpen(folder: folder, bundleID: rule.bundleID, target: target))
        }
    }
    let displays = configuration.displays.filter { !$0.ignored }
    for display in displays {
        for (index, space) in display.spaces.enumerated() {
            for slot in space.layout?.slots ?? [] {
                add(slot.rules, .slot(ConfiguredDesktop(display: display.identity, index: index), slot.id))
            }
        }
    }
    for display in displays {
        for drawer in display.drawers {
            for slot in drawer.layout.slots {
                add(slot.rules, .drawer(display.identity, "\(drawer.edge.rawValue).\(slot.id)"))
            }
        }
    }
    return result
}
