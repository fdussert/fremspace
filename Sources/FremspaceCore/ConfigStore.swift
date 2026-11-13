import Foundation

public enum ConfigError: Error, Equatable {
    /// The file was written by a newer Fremspace; it is left untouched.
    case newerVersion(Int)
    /// The file cannot be read as a configuration; it is left untouched.
    case corrupt(String)
    /// The file changed since it was read (a window command saved it under an open editor).
    case changedOnDisk
}

/// How the file stands against what a caller read from it earlier: what to say, and to offer,
/// when a save was refused because the two differ.
public enum ConfigFileState: Equatable {
    /// It holds what was read.
    case same
    /// It holds another configuration: someone else saved it meanwhile.
    case changed
    /// It is gone (moved, deleted). `load` would answer with an empty configuration, which must
    /// not be taken for the owner's.
    case missing
    /// It is there and cannot be read: why.
    case unreadable(String)
}

/// Reads and writes the configuration file. Never loses a configuration: writes are atomic, the
/// file as it was before the editor's last Save is kept as `config.json.bak`, and a file that
/// cannot be read is never overwritten by `load`. The file may be a link (kept in a dotfiles
/// checkout): the file it points to is replaced, the link stays.
public struct ConfigStore {
    public let url: URL

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fremspace/config.json")
    }

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    public var backupURL: URL { url.appendingPathExtension("bak") }

    /// A missing file is an empty configuration.
    public func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Config(version: Config.currentVersion, configurations: [])
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // The name of the file, not its path: the reason is shown in the status and written
            // to the log, and the path carries the name of the home folder.
            throw ConfigError.corrupt("Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        // The version is checked first, so a newer file is reported as such rather than as
        // corrupt when its shape changed.
        struct Header: Decodable { var version: Int }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw ConfigError.corrupt(Self.describe(error))
        }
        if header.version > Config.currentVersion {
            throw ConfigError.newerVersion(header.version)
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.corrupt(Self.describe(error))
        }
    }

    /// Where the file stands against `previous`, what the caller read from it.
    public func state(since previous: Config) -> ConfigFileState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // No file reads as no configuration: a caller that read that is where the file is.
            return previous.configurations.isEmpty ? .same : .missing
        }
        do {
            return try load() == previous ? .same : .changed
        } catch ConfigError.newerVersion(let version) {
            return .unreadable("It is version \(version), newer than this Fremspace.")
        } catch ConfigError.corrupt(let why) {
            return .unreadable(why)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Saves `config` only when the file still holds `previous` (what the caller read): a change
    /// made meanwhile by someone else is never overwritten.
    public func save(_ config: Config, expecting previous: Config, replacingBackup: Bool = true) throws {
        guard (try? load()) == previous else { throw ConfigError.changedOnDisk }
        try save(config, replacingBackup: replacingBackup)
    }

    /// Writes a temporary file beside the configuration, copies the current file to
    /// `config.json.bak`, then renames the temporary file over the configuration (an atomic
    /// replace: there is always a whole file).
    /// `replacingBackup`: false for the small edits of a window command (two slots swapped, a
    /// window locked, an edge moved). Each of those used to replace the one backup, so that after
    /// a mistake saved in the editor and one swap the backup held the mistake. They leave it as
    /// it is; a file that has no backup yet still gets one.
    public func save(_ config: Config, replacingBackup: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Through a link: renamed over the link itself, the temporary file would replace it with
        // a plain file, and the file it pointed to would silently stop following.
        let target = url.resolvingSymlinksInPath()
        let tmp = target.appendingPathExtension("tmp")
        try data.write(to: tmp)
        // On the disk before it takes the place of the configuration.
        if let handle = try? FileHandle(forWritingTo: tmp) {
            try? handle.synchronize()
            try? handle.close()
        }
        do {
            if fm.fileExists(atPath: target.path), replacingBackup || !fm.fileExists(atPath: backupURL.path) {
                if fm.fileExists(atPath: backupURL.path) {
                    try fm.removeItem(at: backupURL)
                }
                try fm.copyItem(at: target, to: backupURL)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        guard rename(tmp.path, target.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown,
                             userInfo: [NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(code)))"])
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            return "Invalid JSON: \(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            return "Missing \(key.stringValue) at \(path(context))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "\(context.debugDescription) at \(path(context))"
        default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let p = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return p.isEmpty ? "top level" : p
    }
}
