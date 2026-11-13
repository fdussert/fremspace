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
