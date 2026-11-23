import Foundation

/// One row a palette source lists. A source is an executable the owner put in the sources folder:
/// `<source> list` prints its rows as JSON, and a row that is chosen is opened (`url`) or handed
/// back to the source (`<source> run <arg>`). See `extras/palette-sources/README.md`.
public struct SourceItem: Equatable {
    public var title: String
    public var subtitle: String
    /// What the source is run with when the row is chosen.
    public var arg: String?
    /// Opened by Fremspace instead of running the source.
    public var url: URL?
    /// The app (bundle id) the row belongs to: it gives the row its icon and comes to the front
    /// after the action.
    public var app: String?
    /// A short word at the right of the row ("working").
    public var tag: String
    public var keywords: [String]

    public init(title: String, subtitle: String = "", arg: String? = nil, url: URL? = nil, app: String? = nil,
                tag: String = "", keywords: [String] = []) {
        self.title = title
        self.subtitle = subtitle
        self.arg = arg
        self.url = url
        self.app = app
        self.tag = tag
        self.keywords = keywords
    }

    /// What tells this row from the others of its source, and stays the same from one listing to
    /// the next: the palette counts its uses under it.
    public var key: String {
        arg ?? url?.absoluteString ?? title
    }
}

/// What a source may send and how long it may take. A source is the owner's own script, but its
/// output is whatever the tool behind it printed that day.
public enum SourceLimit {
    public static let items = 200
    public static let bytes = 1_048_576
    public static let title = 200
    public static let subtitle = 300
    public static let arg = 4096
    public static let tag = 24
    public static let keywords = 20
    /// A listing slower than this is dropped: the palette is open and waiting.
    public static let listSeconds: TimeInterval = 3
    public static let runSeconds: TimeInterval = 10
}

/// One line of text of at most `limit` characters: a title with a line break or a control
/// character in it would break the row it is drawn in.
private func sourceText(_ value: Any?, limit: Int) -> String {
    guard let text = value as? String else { return "" }
    let line = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
        CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
    })).trimmingCharacters(in: .whitespaces)
    return String(line.prefix(limit))
}

/// The rows in what a source printed for `list`: `{"items": [...]}`, or the list alone. nil when
/// the output is not that at all (the source is then ignored). A row without a title, or with
/// nothing to do when chosen (no `arg`, no `url`, no `app`), is left out; so is one whose `arg`
/// is too long to be handed back whole. No more than `SourceLimit.items` rows are kept.
public func sourceItems(from output: Data) -> [SourceItem]? {
    guard output.count <= SourceLimit.bytes, let json = try? JSONSerialization.jsonObject(with: output) else { return nil }
    let list: [Any]
    if let object = json as? [String: Any], let items = object["items"] as? [Any] {
        list = items
    } else if let items = json as? [Any] {
        list = items
    } else {
        return nil
    }
    var rows: [SourceItem] = []
    for entry in list {
        guard rows.count < SourceLimit.items else { break }
        guard let fields = entry as? [String: Any] else { continue }
        let title = sourceText(fields["title"], limit: SourceLimit.title)
        guard !title.isEmpty else { continue }
        var item = SourceItem(title: title, subtitle: sourceText(fields["subtitle"], limit: SourceLimit.subtitle),
                              tag: sourceText(fields["tag"], limit: SourceLimit.tag))
        if let arg = fields["arg"] as? String, !arg.isEmpty {
            guard arg.count <= SourceLimit.arg else { continue }
            item.arg = arg
        }
        // A link has a scheme: a bare path or a word is not opened as one.
        if let text = fields["url"] as? String, let url = URL(string: text), url.scheme?.isEmpty == false { item.url = url }
        let app = sourceText(fields["app"], limit: 255)
        if !app.isEmpty { item.app = app }
        guard item.arg != nil || item.url != nil || item.app != nil else { continue }
        item.keywords = (fields["keywords"] as? [Any] ?? []).prefix(SourceLimit.keywords)
            .map { sourceText($0, limit: SourceLimit.title) }.filter { !$0.isEmpty }
        rows.append(item)
    }
    return rows
}

/// Whether a file of the sources folder is run: a regular file, not hidden, that the person
/// Fremspace runs as owns and may execute, and that nobody else may write. What is run from this
/// folder runs as the owner, so a file somebody else could have changed is not.
public func sourceMayRun(name: String, isRegularFile: Bool, permissions: Int, owner: UInt32, user: UInt32) -> Bool {
    !name.hasPrefix(".") && isRegularFile && owner == user && permissions & 0o100 != 0 && permissions & 0o022 == 0
}

/// The name a source goes by: its file name without the extension ("tmux" for `tmux.sh`).
public func sourceName(file: String) -> String {
    let name = (file as NSString).deletingPathExtension
    return name.isEmpty ? file : name
}

/// The palette's row for a row of a source. Its id and its use key carry the source's name, so
/// two sources that list the same thing stay apart.
public func paletteItem(_ item: SourceItem, source: String) -> PaletteItem {
    PaletteItem(id: "x:\(source):\(item.key)", kind: .extra, title: item.title, subtitle: item.subtitle,
                keywords: item.keywords + [source])
}

/// What a source runs with: the usual places of command-line tools first, since an app started
/// by the Finder has only the system's.
public func sourceEnvironment(home: String, user: String, temporary: String) -> [String: String] {
    ["PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
     "HOME": home, "USER": user, "LOGNAME": user, "TMPDIR": temporary, "LANG": "en_US.UTF-8", "FREMSPACE_PALETTE": "1"]
}
