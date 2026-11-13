import Foundation

// What the editor writes and draws about a slot, kept here so that it can be tested without a window.

/// A share of a display as the editor writes it: a clean fraction in full-size digits ("3/5"),
/// "full" for the whole, else a percentage. The single-character fractions (⅗) are not used: at
/// the size of a tile's caption their digits are three points high.
public func fractionLabel(_ value: Double) -> String {
    cleanFraction(value) ?? percentLabel(value)
}

/// A slot's size on its tile: the width alone when the slot is as high as the display, else width
/// by height. One notation per label: both as fractions, or both as percentages when either is
/// off the grid ("40 × 55 %"), so that the eye does not switch scale in the middle.
public func sizeLabel(width: Double, height: Double) -> String {
    guard height < 0.999 else { return fractionLabel(width) }
    if let w = cleanFraction(width), let h = cleanFraction(height) { return "\(w) × \(h)" }
    return "\(percentNumber(width)) × \(percentLabel(height))"
}

/// The same size in words, for the inspector: "3/5 wide, full height".
public func sizeWords(width: Double, height: Double) -> String {
    let w = abs(width - 1) < 0.001 ? "full width" : "\(fractionLabel(width)) wide"
    let h = abs(height - 1) < 0.001 ? "full height" : "\(fractionLabel(height)) high"
    return "\(w), \(h)"
}

private func cleanFraction(_ value: Double) -> String? {
    let names: [(Double, String)] = [(1, "full"), (0.5, "1/2"), (1.0 / 3, "1/3"), (2.0 / 3, "2/3"), (0.4, "2/5"), (0.6, "3/5"),
                                     (0.25, "1/4"), (0.75, "3/4"), (0.125, "1/8"), (0.375, "3/8"), (0.625, "5/8"), (0.875, "7/8")]
    return names.first { abs($0.0 - value) < 0.001 }?.1
}

private func percentNumber(_ value: Double) -> Int { Int((value * 100).rounded()) }

private func percentLabel(_ value: Double) -> String { "\(percentNumber(value)) %" }

/// What a slot's tile shows in the room it has on the editor's screen. The title is always there;
/// the size, the states and the app icons come as they fit, so that nothing is drawn over
/// something else on a small display, in a narrow slot or in a small window.
public struct TileFit: Equatable {
    /// The size line under the title.
    public var size: Bool
    /// The row of states at the bottom of the tile.
    public var states: Bool
    /// Each state with its word beside its symbol, not the symbol alone.
    public var stateWords: Bool
    /// The side of each app icon; nil when none fits between the title and the states.
    public var icon: Double?

    public init(size: Bool, states: Bool, stateWords: Bool, icon: Double?) {
        self.size = size
        self.states = states
        self.stateWords = stateWords
        self.icon = icon
    }
}

/// The measures of a tile the fit is computed with; the view lays the tile out with the same ones.
public enum TileMetrics {
    public static let padding = 7.0
    public static let titleLine = 15.0
    public static let sizeLine = 15.0
    public static let stateRow = 18.0
    /// Kept clear above and under the icons.
    public static let iconGap = 4.0
    public static let largestIcon = 64.0
    /// Under this an icon is a smudge: the title says which app it is.
    public static let smallestIcon = 20.0
    /// The width a state takes with its word ("Unlocked" is the longest).
    public static let stateWithWord = 86.0
}

/// The fit of a tile `width` by `height` points that has `apps` icons to show and `states` things to
/// say about how the slot behaves.
public func tileFit(width: Double, height: Double, apps: Int, states: Int) -> TileFit {
    let m = TileMetrics.self
    let title = m.padding + m.titleLine
    let showsStates = states > 0 && height >= title + m.iconGap + m.stateRow + m.padding
    let foot = m.padding + (showsStates ? m.stateRow : 0)
    let stateWords = showsStates && width >= 2 * m.padding + m.stateWithWord * Double(states)
    let sizeFits = width >= 90 && height >= title + m.sizeLine + (showsStates ? m.iconGap : 0) + foot

    /// The side of the icons in what the text leaves, nil when they would be a smudge.
    func icon(underSize: Bool) -> Double? {
        guard apps > 0 else { return nil }
        let room = height - title - (underSize ? m.sizeLine : 0) - foot - 2 * m.iconGap
        // The icons stand in a row, a fifth of their side apart.
        let across = (width - 2 * m.padding) / (1.2 * Double(apps) - 0.2)
        let side = min(m.largestIcon, room, across)
        return side >= m.smallestIcon ? side.rounded(.down) : nil
    }

    // What says the most stays the longest: the states, then the icon, then the size, which the
    // inspector gives too. So the size line goes when that is what lets the icon in.
    if sizeFits, apps > 0, icon(underSize: true) == nil, let alone = icon(underSize: false) {
        return TileFit(size: false, states: showsStates, stateWords: stateWords, icon: alone)
    }
    return TileFit(size: sizeFits, states: showsStates, stateWords: stateWords, icon: icon(underSize: sizeFits))
}

/// The desktops a new configuration gives a display: as many as macOS has there, at least one, all
/// free, so that the editor's tabs match Mission Control from the first minute.
public func starterDesktops(count: Int) -> [SpaceSpec] {
    (1...max(1, count)).map { SpaceSpec(label: "Desktop \($0)") }
}
