import CoreGraphics
import Foundation

/// Window titles of Chromium browsers end with the browser's name, then the profile when there are
/// several: "<page> - Brave – Work". The dashes are the translators': English writes a hyphen
/// before the name and an en dash before the profile, French an en dash before "Brave" and a
/// hyphen before "Google Chrome", Spanish a non-breaking hyphen before "Brave Beta" (read in the
/// browsers' own strings, 2026-11-14, after a French Brave showed no profile at all).
private let browserNames = ["Brave", "Brave Beta", "Brave Dev", "Brave Nightly",
                            "Google Chrome", "Google Chrome Beta", "Google Chrome Dev", "Google Chrome Canary",
                            "Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev", "Microsoft Edge Canary",
                            "Chromium", "Vivaldi", "Arc"]

/// Hyphen, en dash, em dash, non-breaking hyphen: what stands between the parts of a title.
private let titleDashes: Set<Character> = ["-", "\u{2013}", "\u{2014}", "\u{2011}"]

/// Whether `text` ends with " <dash> ", and the text before it.
private func droppingDash(atEndOf text: Substring) -> Substring? {
    let characters = Array(text.suffix(3))
    guard characters.count == 3, characters[0].isWhitespace, titleDashes.contains(characters[1]), characters[2].isWhitespace
    else { return nil }
    return text.dropLast(3)
}

/// The browser profile in a tabbed browser's window title, nil when the title names none: what
/// follows the browser's name and a dash, from the last place where that name stands as a part of
/// the title. A profile's own name may hold a dash ("Work - Client"). A title that ends with the
/// browser's name has no profile, whatever its page is called.
public func browserProfile(fromTitle title: String, bundleID: String) -> String? {
    guard isTabbedBrowser(bundleID) else { return nil }
    // The longest names first: "Brave Beta" is not "Brave" followed by something.
    let names = browserNames.sorted { $0.count > $1.count }
    let whole = title.trimmingCharacters(in: .whitespaces)
    if names.contains(where: { whole == $0 || (whole.hasSuffix($0) && droppingDash(atEndOf: whole.dropLast($0.count)) != nil) }) {
        return nil
    }
    var best: (start: String.Index, profile: Substring)?
    for name in names {
        var search = whole.startIndex..<whole.endIndex
        while let found = whole.range(of: name, options: .backwards, range: search) {
            search = whole.startIndex..<found.lowerBound
            // A part of the title: at its start or after a dash, and followed by a dash.
            let before = whole[..<found.lowerBound]
            guard before.isEmpty || droppingDash(atEndOf: before) != nil else { continue }
            let after = whole[found.upperBound...]
            let lead = Array(after.prefix(3))
            guard lead.count == 3, lead[0].isWhitespace, titleDashes.contains(lead[1]), lead[2].isWhitespace else { continue }
            if best.map({ found.lowerBound > $0.start }) ?? true { best = (found.lowerBound, after.dropFirst(3)) }
            break
        }
    }
    guard let profile = best?.profile.trimmingCharacters(in: .whitespaces), !profile.isEmpty else { return nil }
    return profile
}

private let tabNoise = try! NSRegularExpression(
    pattern: #"(\s[-\u2013]\s(Memory usage|High memory usage|Inactive tab|Audio playing|Audio muted|Network error|Utilisation de la mémoire|Utilisation élevée de la mémoire|Onglet inactif)(\s[-\u2013]\s[\d.,]+\s?[KMGT]?[Bo](\s\p{L}+)*)?)+$"#)

/// In English and in French, as the browsers' strings have them; a browser in another language
/// keeps these suffixes, and its windows are recognised less well after a restart of the Mac.
/// A tab title without what Brave appends to it (memory use, "Inactive tab"). A size may be
/// followed by a word: a tab put to sleep reads "Inactive tab - 123 MB freed", which was left on
/// (owner, 2026-11-14: after a restart of the Mac no tab is asleep yet, 18 of a window's 47 tabs
/// differed from what was remembered by that suffix alone, and the window was not recognised).
public func normalizedTabTitle(_ title: String) -> String {
    let range = NSRange(title.startIndex..., in: title)
    return tabNoise.stringByReplacingMatches(in: title, range: range, withTemplate: "")
        .trimmingCharacters(in: .whitespaces)
}

/// What recognises a window after its app relaunched (new window ids): the browser profile and the
/// set of tab titles, the document of an editor, else the title.
public struct WindowIdentity: Codable, Equatable {
    public var bundleID: String
    public var profile: String?
    /// The document's URL (editors), when the window exposes one.
    public var document: String?
    public var title: String
    /// Normalised, unique, sorted.
    public var tabs: [String]
    public var size: CGSize

    public init(bundleID: String, profile: String?, document: String?, title: String, tabs: [String], size: CGSize) {
        self.bundleID = bundleID
        self.profile = profile
        self.document = document.flatMap { $0.isEmpty ? nil : $0 }
        self.title = title
        self.tabs = Array(Set(tabs.map(normalizedTabTitle).filter { !$0.isEmpty })).sorted()
        self.size = size
    }
}

/// How alike two windows are, 0...1. Never alike across apps or profiles; the same document is
/// certain; tabbed windows compare their sets of tabs (Jaccard); others their titles.
public func similarity(_ a: WindowIdentity, _ b: WindowIdentity) -> Double {
    guard a.bundleID == b.bundleID, a.profile == b.profile else { return 0 }
    if let da = a.document, let db = b.document { return da == db ? 1 : 0 }
    if !a.tabs.isEmpty, !b.tabs.isEmpty {
        // Normalised again: what was remembered by an earlier build still carries what that build
        // did not remove.
        let sa = Set(a.tabs.map(normalizedTabTitle)), sb = Set(b.tabs.map(normalizedTabTitle))
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }
    return a.title == b.title ? 0.9 : 0
}

/// Live window id → index in `remembered`, each used once: the most alike pairs first, ties broken
/// by the closest size, then the lower window id. Pairs below `threshold` stay unmatched.
public func matchIdentities(live: [UInt32: WindowIdentity], remembered: [WindowIdentity],
                            threshold: Double = 0.5) -> [UInt32: Int] {
    struct Pair { var id: UInt32; var index: Int; var score: Double; var sizeGap: CGFloat }
    var pairs: [Pair] = []
    for (id, identity) in live {
        for (index, old) in remembered.enumerated() {
            let score = similarity(identity, old)
            guard score >= threshold else { continue }
            let gap = abs(identity.size.width - old.size.width) + abs(identity.size.height - old.size.height)
            pairs.append(Pair(id: id, index: index, score: score, sizeGap: gap))
        }
    }
    pairs.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        if a.sizeGap != b.sizeGap { return a.sizeGap < b.sizeGap }
        if a.id != b.id { return a.id < b.id }
        return a.index < b.index
    }
    var result: [UInt32: Int] = [:]
    var used: Set<Int> = []
    for pair in pairs where result[pair.id] == nil && !used.contains(pair.index) {
        result[pair.id] = pair.index
        used.insert(pair.index)
    }
    return result
}
