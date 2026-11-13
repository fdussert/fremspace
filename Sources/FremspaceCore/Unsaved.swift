import Foundation

/// Where the configuration being edited differs from the file: what the editor marks in its sidebar
/// and names beside Save, so that "unsaved changes" also says where they are. A change can be on a
/// page the owner left three clicks ago.
public struct UnsavedChanges: Equatable {
    /// The configurations that are new or changed (their scenes included), by id.
    public var configurations: Set<UUID> = []
    /// How many configurations of the file were deleted.
    public var deleted = 0
    /// The scenes of some configuration changed.
    public var scenes = false
    /// A setting of the General page changed.
    public var general = false
    /// A shortcut changed, or the Hyper key.
    public var shortcuts = false

    public init() {}

    public var isEmpty: Bool { configurations.isEmpty && deleted == 0 && !general && !shortcuts }
}

public func unsavedChanges(edited: Config, saved: Config) -> UnsavedChanges {
    var changes = UnsavedChanges()
    let before = Dictionary(saved.configurations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for configuration in edited.configurations {
        let was = before[configuration.id]
        if was != configuration { changes.configurations.insert(configuration.id) }
        if (was?.scenes ?? []) != configuration.scenes { changes.scenes = true }
    }
    let kept = Set(edited.configurations.map(\.id))
    changes.deleted = saved.configurations.filter { !kept.contains($0.id) }.count
    changes.general = edited.noFloating != saved.noFloating || edited.floatingApps != saved.floatingApps
        || edited.resizeLayouts != saved.resizeLayouts
        || edited.desktopNames != saved.desktopNames || edited.notchMap != saved.notchMap
        || edited.windowPreviews != saved.windowPreviews || edited.fullScreenCalls != saved.fullScreenCalls
    changes.shortcuts = edited.shortcuts != saved.shortcuts || edited.hyperKey != saved.hyperKey
    return changes
}

/// The places of `changes` as the owner names them, in the order of the sidebar: the configurations
/// by their name, then the pages. For "Unsaved changes in Desk and Shortcuts."
public func unsavedPlaces(_ changes: UnsavedChanges, in edited: Config) -> [String] {
    var places = edited.configurations.filter { changes.configurations.contains($0.id) }
        .map { $0.name.isEmpty ? "Untitled" : $0.name }
    if changes.deleted == 1 { places.append("a deleted configuration") }
    if changes.deleted > 1 { places.append("\(changes.deleted) deleted configurations") }
    if changes.general { places.append("General") }
    if changes.shortcuts { places.append("Shortcuts") }
    return places
}

/// "A", "A and B", "A, B and C".
public func listed(_ words: [String]) -> String {
    guard words.count > 1, let last = words.last else { return words.first ?? "" }
    return words.dropLast().joined(separator: ", ") + " and " + last
}
