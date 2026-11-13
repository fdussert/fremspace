import CoreGraphics
import Foundation

/// The configuration to use for the connected displays: among those whose displays are all
/// connected, the one with the most displays; the first one on a tie. Nil when none fits.
/// Ignored displays are optional (owner, 2026-11-10: unplugging the ignored Xeneon Edge must not
/// switch the whole configuration off): only the displays Fremspace arranges are required and
/// counted, and a configuration needs at least one.
/// (Plan 3 replaces this with proper detection and a menu override.)
public func chooseConfiguration(_ config: Config, connected: [DisplayIdentity]) -> Configuration? {
    let present = Set(connected)
    var best: (configuration: Configuration, required: Int)?
    for candidate in config.configurations {
        let required = candidate.displays.filter { !$0.ignored }
        guard !required.isEmpty, required.allSatisfy({ present.contains($0.identity) }) else { continue }
        if required.count > (best?.required ?? -1) {
            best = (candidate, required.count)
        }
    }
    return best?.configuration
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
