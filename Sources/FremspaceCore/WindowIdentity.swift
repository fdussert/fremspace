import CoreGraphics
import Foundation

/// Window titles of Chromium browsers end with the browser's name, then the profile when there are
/// several: "<page> - Brave – Work" (en dash before the profile).
private let browserNames = ["Brave", "Google Chrome", "Microsoft Edge", "Chromium", "Vivaldi", "Arc"]

/// The browser profile in a tabbed browser's window title, nil when the title names none.
public func browserProfile(fromTitle title: String, bundleID: String) -> String? {
    guard isTabbedBrowser(bundleID), let separator = title.range(of: " – ", options: .backwards) else { return nil }
    let head = title[..<separator.lowerBound]
    let profile = title[separator.upperBound...].trimmingCharacters(in: .whitespaces)
    guard !profile.isEmpty, !profile.contains(" - "),
          browserNames.contains(where: { head == $0 || head.hasSuffix(" - " + $0) }) else { return nil }
    return profile
}

private let tabNoise = try! NSRegularExpression(
    pattern: #"(\s-\s(Memory usage|Inactive tab|Audio playing|Network error)(\s-\s[\d.,]+\s?[KMGT]?B)?)+$"#)

/// A tab title without what Brave appends to it (memory use, "Inactive tab").
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
        let sa = Set(a.tabs), sb = Set(b.tabs)
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
