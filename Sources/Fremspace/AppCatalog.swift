import AppKit

/// The apps installed on this Mac, for the palette: read in the background when the palette opens,
/// so an app installed meanwhile is there the next time.
final class AppCatalog {
    struct App: Equatable {
        /// As Finder shows it ("Calculette").
        var name: String
        /// The bundle's file name ("Calculator"): the owner may type either.
        var fileName: String
        var url: URL
        var bundleID: String?
    }

    private(set) var apps: [App] = []
    private var scanning = false
    /// Called on the main thread when a scan changed the list.
    var onChange: (() -> Void)?

    static let folders: [String] = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications",
    ]

    func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                guard found != self.apps else { return }
                self.apps = found
                self.onChange?()
            }
        }
    }

    /// The apps of the usual folders and of the folders one level inside them (a suite's folder).
    static func scan() -> [App] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var result: [App] = []
        func add(_ url: URL) {
            let bundleID = Bundle(url: url)?.bundleIdentifier
            // The same app in two folders: the first folder wins.
            guard seen.insert(bundleID ?? url.path).inserted else { return }
            var name = fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            result.append(App(name: name, fileName: url.deletingPathExtension().lastPathComponent, url: url, bundleID: bundleID))
        }
        func children(_ path: String) -> [URL] {
            (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles])) ?? []
        }
        for folder in folders {
            for url in children(folder) {
                if url.pathExtension == "app" {
                    add(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, !folders.contains(url.path) {
                    children(url.path).filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
