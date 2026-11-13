import Foundation

/// What a row of the palette opens.
public enum PaletteKind: Int, Equatable {
    case window, app, desktop, command
}

/// One thing the palette can open: an open window, an app to launch, a desktop to show, a command.
public struct PaletteItem: Equatable, Identifiable {
    public var id: String
    public var kind: PaletteKind
    public var title: String
    /// Shown under the title; searched too, for less.
    public var subtitle: String
    /// Other names the item answers to (an app's file name next to its localized name), not shown.
    public var keywords: [String]
    /// The key its uses are counted under: an app for all its windows (window ids do not last).
    public var useKey: String

    public init(id: String, kind: PaletteKind, title: String, subtitle: String = "", keywords: [String] = [],
                useKey: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.useKey = useKey ?? id
    }
}

/// Lower case, without accents: "Réglages" is found by "regl".
public func paletteFold(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
}

/// How well one word of the query matches `text` (already folded), nil when it does not. The whole
/// text beats its start, which beats the start of a word, which beats initials ("vsc" for Visual
/// Studio Code), which beat the middle of a word; a word typed with letters missing comes last.
public func paletteScore(word: String, in text: String) -> Int? {
    guard !word.isEmpty, !text.isEmpty else { return nil }
    if text == word { return 100 }
    if text.hasPrefix(word) { return 90 }
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    if words.contains(where: { $0.hasPrefix(word) }) { return 75 }
    if words.count > 1, String(words.compactMap(\.first)).hasPrefix(word) { return 60 }
    if text.contains(word) { return 50 }
    // A letter left out ("slk"): inside one word, from its first letter. Across words it would match
    // almost anything.
    guard word.count >= 3 else { return nil }
    for candidate in words where candidate.first == word.first {
        var rest = Substring(candidate)
        var found = true
        for character in word {
            guard let index = rest.firstIndex(of: character) else { found = false; break }
            rest = rest[rest.index(after: index)...]
        }
        if found { return 20 }
    }
    return nil
}

/// The score of an item for a query of several words: every word has to match the title, a keyword
/// or the subtitle (the title counts in full, the others for less). Nil when a word matches nothing.
public func paletteScore(_ query: String, item: PaletteItem) -> Int? {
    let words = paletteFold(query).split(separator: " ").map(String.init)
    guard !words.isEmpty else { return 0 }
    let title = paletteFold(item.title)
    let keywords = item.keywords.map(paletteFold)
    let subtitle = paletteFold(item.subtitle)
    var total = 0
    for word in words {
        var best = paletteScore(word: word, in: title)
        for keyword in keywords {
            if let score = paletteScore(word: word, in: keyword).map({ $0 - 10 }), score > best ?? Int.min { best = score }
        }
        // Letters apart in a subtitle match almost anything: only whole pieces of it count.
        if let score = paletteScore(word: word, in: subtitle), score >= 50, score - 30 > best ?? Int.min { best = score - 30 }
        guard let best else { return nil }
        total += best
    }
    return total / words.count
}

/// The rows for `query`, best first. `items` come in the order to show without a query (windows,
/// the most recent first); without a query only the windows are listed. Among equal matches the item
/// opened most often wins (`uses`, by `useKey`), then a window over an app, a desktop and a command,
/// then the order given.
public func paletteResults(_ query: String, items: [PaletteItem], uses: [String: Int] = [:], limit: Int = 30) -> [PaletteItem] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
        return Array(items.filter { $0.kind == .window }.prefix(limit))
    }
    var scored: [(item: PaletteItem, score: Int, order: Int)] = []
    for (order, item) in items.enumerated() {
        guard let score = paletteScore(query, item: item) else { continue }
        scored.append((item, score + min(uses[item.useKey] ?? 0, 10) * 3, order))
    }
    scored.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        if a.item.kind != b.item.kind { return a.item.kind.rawValue < b.item.kind.rawValue }
        return a.order < b.order
    }
    return scored.prefix(limit).map(\.item)
}

/// A desktop on the map of desktops: the row of its display, and its position in it.
public struct MapPlace: Equatable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Where an arrow key takes the chosen desktop of the map.
public enum MapMove: Equatable {
    case to(MapPlace)
    /// Up from the first row, down from the last: out of the map.
    case above, below
}

/// One arrow key on the map. `rows` is how many desktops each display has. Left and right stay in
/// the row and stop at its ends; up and down keep the position when the other row has it, else
/// take its last desktop.
public func mapMove(rows: [Int], from place: MapPlace, dx: Int, dy: Int) -> MapMove {
    guard rows.indices.contains(place.row), rows[place.row] > 0 else { return .to(place) }
    if dy != 0 {
        var row = place.row + (dy > 0 ? 1 : -1)
        // A display without desktop on the map has no row to stop on.
        while rows.indices.contains(row), rows[row] == 0 { row += dy > 0 ? 1 : -1 }
        guard row >= 0 else { return .above }
        guard row < rows.count else { return .below }
        return .to(MapPlace(row: row, column: min(place.column, rows[row] - 1)))
    }
    let column = min(max(place.column + (dx > 0 ? 1 : dx < 0 ? -1 : 0), 0), rows[place.row] - 1)
    return .to(MapPlace(row: place.row, column: column))
}
