import CoreGraphics

/// A window as the engine sees it before a placement pass: where it is (desktop, frame).
public struct SeenWindow: Equatable {
    public var info: WindowInfo
    /// The desktop it is on (real position), nil when unknown.
    public var space: SpaceKey?
    /// Its frame, nil when it could not be read.
    public var frame: CGRect?

    public init(info: WindowInfo, space: SpaceKey?, frame: CGRect?) {
        self.info = info
        self.space = space
        self.frame = frame
    }
}

/// The slot a window holds: slot ids repeat from one desktop to the next (`main`, the ids made
/// from an app's name), so a slot is one of a desktop.
public struct HeldSlot: Equatable {
    public var space: SpaceKey
    public var slotID: String

    public init(space: SpaceKey, slotID: String) {
        self.space = space
        self.slotID = slotID
    }
}

/// Everything a placement pass decides from.
public struct PlanInput {
    /// The desktop each display shows, with its spec (only configured desktops).
    public var desktops: [SpaceKey: SpaceSpec]
    /// The visible frame of each display (AX coordinates).
    public var visible: [DisplayIdentity: CGRect]
    public var windows: [SeenWindow]
    /// The slot each window holds now, and on which desktop (the engine's placements).
    public var held: [UInt32: HeldSlot]
    /// The slot the user dropped each live window into.
    public var chosen: [UInt32: String]
    /// Where the owner last dropped a window of that app, profile and title, per desktop: the
    /// slot it remembers is one of that desktop, and slot ids repeat from one desktop to the next.
    public var memory: [SpaceKey: [WindowKey: String]]
    /// Released windows and drawer members: never planned.
    public var skip: Set<UInt32>
    /// Windows whose app refuses their slot size.
    public var cannotFit: Set<UInt32>
    public var focus: [SpaceKey: String]
    /// Also put back windows of unlocked slots and windows that cannot fit.
    public var force: Bool
    /// Limit the pass to one desktop.
    public var only: SpaceKey?
    public var gap: CGFloat
    /// Frames this close are the same (as `LockGuard.tolerance`).
    public var tolerance: CGFloat
    /// Windows that share their slot side by side with another (see `SplitSide`).
    public var split: [UInt32: SplitSide]
    /// Desktops whose Focus was given or taken while they were not shown: their windows could
    /// not move then, so the pass is forced for them once they are shown.
    public var refocused: Set<SpaceKey>

    public init(desktops: [SpaceKey: SpaceSpec], visible: [DisplayIdentity: CGRect], windows: [SeenWindow],
                held: [UInt32: HeldSlot], chosen: [UInt32: String], memory: [SpaceKey: [WindowKey: String]], skip: Set<UInt32>,
                cannotFit: Set<UInt32>, focus: [SpaceKey: String], force: Bool, only: SpaceKey?, gap: CGFloat,
                tolerance: CGFloat, split: [UInt32: SplitSide] = [:], refocused: Set<SpaceKey> = []) {
        self.desktops = desktops
        self.visible = visible
        self.windows = windows
        self.held = held
        self.chosen = chosen
        self.memory = memory
        self.skip = skip
        self.cannotFit = cannotFit
        self.focus = focus
        self.force = force
        self.only = only
        self.gap = gap
        self.tolerance = tolerance
        self.split = split
        self.refocused = refocused
    }
}

/// A window the pass puts in a slot. `move` is nil when its frame needs no change.
public struct PlannedPlacement: Equatable {
    public var id: UInt32
    public var space: SpaceKey
    public var slotID: String
    public var frame: CGRect
    public var locked: Bool
    public var move: Move?

    public init(id: UInt32, space: SpaceKey, slotID: String, frame: CGRect, locked: Bool, move: Move?) {
        self.id = id
        self.space = space
        self.slotID = slotID
        self.frame = frame
        self.locked = locked
        self.move = move
    }
}

/// Which slot each window of the shown desktops takes, and which windows must be moved there.
/// A window that already holds its slot on that desktop is moved again only when the slot is locked
/// (and the window can fit) or the pass is forced; a window within `tolerance` of its slot frame
/// is not moved. A slot of the same id held on another desktop is another slot: a window taken by
/// hand to a desktop is placed there like one that opens there.
public func planPlacements(_ input: PlanInput) -> [PlannedPlacement] {
    var result: [PlannedPlacement] = []
    let keys = input.desktops.keys.sorted { ($0.display.name, $0.spaceIndex) < ($1.display.name, $1.spaceIndex) }
    for space in keys {
        guard let spec = input.desktops[space], let layout = spec.layout,
              let visible = input.visible[space.display] else { continue }
        if let only = input.only, only != space { continue }
        let here = input.windows.filter { $0.space == space && !input.skip.contains($0.info.id) }
        let assignment = assign(windows: here.map(\.info), layout: layout, memory: input.memory[space] ?? [:],
                                chosen: input.chosen)
        let frames = slotFrames(layout: layout, focus: input.focus[space], visible: visible, gap: input.gap)
        for seen in here {
            let id = seen.info.id
            guard let slotID = assignment.placed[id], var frame = frames[slotID],
                  let slot = layout.slots.first(where: { $0.id == slotID }) else { continue }
            // Side by side with its partner while both are in the slot they were split in; alone
            // or elsewhere, the window has its slot whole.
            if let side = input.split[id], side.slotID == slotID, assignment.placed[side.partner] == slotID {
                frame = halfFrame(frame, side.half, gap: input.gap)
            }
            var planned = PlannedPlacement(id: id, space: space, slotID: slotID, frame: frame, locked: slot.locked,
                                           move: nil)
            let alreadyPlaced = input.held[id] == HeldSlot(space: space, slotID: slotID)
            let force = input.force || input.refocused.contains(space)
            let leave = alreadyPlaced && (!slot.locked || input.cannotFit.contains(id)) && !force
            if !leave, let actual = seen.frame, !isClose(actual, frame, tolerance: input.tolerance) {
                planned.move = Move(id: id, from: actual, to: frame)
            }
            result.append(planned)
        }
    }
    return result
}

private func isClose(_ a: CGRect, _ b: CGRect, tolerance t: CGFloat) -> Bool {
    abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t
        && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
}
