import CoreGraphics
import Foundation

/// The configurations the connected displays allow, in the order of the file: those whose displays
/// are all connected. Ignored displays are optional (owner, 2026-11-10: unplugging the ignored
/// Xeneon Edge must not switch the whole configuration off): only the displays Fremspace arranges
/// are required, and a configuration needs at least one.
public func fittingConfigurations(_ config: Config, connected: [DisplayIdentity]) -> [Configuration] {
    let present = Set(connected)
    return config.configurations.filter { candidate in
        let required = candidate.displays.filter { !$0.ignored }
        return !required.isEmpty && required.allSatisfy { present.contains($0.identity) }
    }
}

/// The configuration to use for the connected displays. `chosen`, the one the owner picked for
/// these displays, when it still fits them (owner, 2026-11-14: a copy that arranges one display
/// more was taken instead of the original, with no way back but deleting it). Else, among those
/// that fit, the one that arranges the most displays; the first one on a tie. Nil when none fits.
public func chooseConfiguration(_ config: Config, connected: [DisplayIdentity], chosen: UUID? = nil) -> Configuration? {
    let fitting = fittingConfigurations(config, connected: connected)
    if let chosen, let picked = fitting.first(where: { $0.id == chosen }) { return picked }
    var best: (configuration: Configuration, required: Int)?
    for candidate in fitting {
        let required = candidate.displays.filter { !$0.ignored }.count
        if required > (best?.required ?? -1) { best = (candidate, required) }
    }
    return best?.configuration
}

/// The name under which the owner's choice of configuration is kept for a set of displays: the
/// choice made at the desk says nothing about the laptop alone. The displays' names are left out,
/// they change with the language of the Mac.
public func deskKey(_ connected: [DisplayIdentity]) -> String {
    connected.map { "\($0.vendor)-\($0.model)-\($0.serial)" }.sorted().joined(separator: "+")
}

/// A connected display: the whole of it, and the room the menu bar and the Dock leave.
public struct DisplayArea: Equatable {
    public var identity: DisplayIdentity
    public var frame: CGRect
    public var visible: CGRect

    public init(identity: DisplayIdentity, frame: CGRect, visible: CGRect) {
        self.identity = identity
        self.frame = frame
        self.visible = visible
    }
}

/// What macOS means when it says the screens changed. It says so for a display plugged in,
/// unplugged, moved or resized, and also when only the room left to windows changes: the Dock
/// shown on another display, a menu bar that hides (owner, 2026-11-13: taking the Dock to the
/// display of the drawers brought both drawers out, as an unplugged display does).
public enum DisplaysChange: Equatable {
    case none
    /// The same displays at the same places: the layouts fit another room, nothing else moves.
    case visibleArea
    case displays
}

public func displaysChange(from old: [DisplayArea], to new: [DisplayArea]) -> DisplaysChange {
    guard old.count == new.count,
          old.allSatisfy({ was in new.contains { $0.identity == was.identity && $0.frame == was.frame } }) else { return .displays }
    return old.allSatisfy(new.contains) ? .none : .visibleArea
}

/// How long the displays must stay as they are before Fremspace acts on a change of displays.
/// A Mac that wakes says so in steps: its own display alone, then the others, seconds apart
/// (owner, 2026-11-14: one display, and the four of them 4.3 s later; acting on each step brought
/// the drawers out and left the windows where macOS had dropped them). `before` is what Fremspace
/// last acted on, `now` what macOS says, `waking` whether the Mac or its displays slept since.
/// Displays that are back as they were need no more waiting than macOS takes to hand the windows
/// back; other displays may be a step on the way, and a waking Mac takes longer between steps.
public func displaySettleDelay(before: [DisplayArea], now: [DisplayArea], waking: Bool) -> TimeInterval {
    if displaysChange(from: before, to: now) != .displays { return 1.5 }
    return waking ? 8 : 2
}

/// The slot whose frame centre is closest to the centre of `frame`: where the user dropped a window.
public func nearestSlot(to frame: CGRect, among frames: [String: CGRect]) -> String? {
    func distance(_ r: CGRect) -> CGFloat {
        hypot(r.midX - frame.midX, r.midY - frame.midY)
    }
    return frames.min { a, b in
        let da = distance(a.value), db = distance(b.value)
        return da == db ? a.key < b.key : da < db
    }?.key
}

/// A display of `configuration` (not ignored) that two or more connected displays report as their
/// identity: Fremspace cannot tell them apart, so it must not place windows for that configuration.
public func ambiguousDisplay(connected: [DisplayIdentity], in configuration: Configuration) -> DisplayIdentity? {
    var counts: [DisplayIdentity: Int] = [:]
    for identity in connected { counts[identity, default: 0] += 1 }
    return configuration.displays.first { !$0.ignored && (counts[$0.identity] ?? 0) > 1 }?.identity
}
