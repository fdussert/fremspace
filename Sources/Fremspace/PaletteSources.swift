import AppKit
import FremspaceCore

/// Runs the palette's sources: the executables the owner put in the "Palette Sources" folder, each
/// asked for its rows (`<source> list`) when the palette opens and handed back the row that is
/// chosen (`<source> run <arg>`). Only when the owner switched the setting on; only files of that
/// folder that are the owner's own (`sourceMayRun`); nothing a row says is ever run as a command.
final class PaletteSources {
    static var folder: URL {
        ConfigStore.defaultURL.deletingLastPathComponent().appendingPathComponent("Palette Sources", isDirectory: true)
    }

    struct Listing: Equatable {
        var script: URL
        var name: String
        var items: [SourceItem]
    }

    /// What the sources listed last: shown at once when the palette opens, while they are asked again.
    private(set) var listings: [Listing] = []
    private var refreshing = false
    private var refreshed = Date.distantPast

    /// The files of the folder that are run, by name.
    static func scripts() -> [URL] {
        let manager = FileManager.default
        let user = getuid()
        // A folder somebody else may write could be given a file of theirs: nothing in it is run.
        guard let folder = try? manager.attributesOfItem(atPath: Self.folder.path),
              (folder[.ownerAccountID] as? NSNumber)?.uint32Value == user,
              ((folder[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0,
              let names = try? manager.contentsOfDirectory(atPath: Self.folder.path) else { return [] }
        return names.sorted().compactMap { name in
            // Through a link, to the file it names: the owner may keep the scripts elsewhere.
            let url = Self.folder.appendingPathComponent(name).resolvingSymlinksInPath()
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  sourceMayRun(name: name, isRegularFile: attributes[.type] as? FileAttributeType == .typeRegular,
                               permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
                               owner: (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? .max, user: user)
            else { return nil }
            return Self.folder.appendingPathComponent(name)
        }
    }

    /// Asks every source for its rows, off the main thread. `then` is called on the main thread
    /// each time a source answered with rows that changed: a slow source does not keep back the
    /// rows of the others. Not more than once every other second: the palette is opened and
    /// closed in bursts.
    func refresh(then: @escaping () -> Void) {
        guard !refreshing, Date().timeIntervalSince(refreshed) > 2 else { return }
        let scripts = Self.scripts()
        // A source that is gone from the folder takes its rows with it.
        let kept = listings.filter { scripts.contains($0.script) }
        if kept != listings {
            listings = kept
            then()
        }
        guard !scripts.isEmpty else { return }
        refreshing = true
        let started = Date()
        var waiting = scripts.count
        for script in scripts {
            let name = sourceName(file: script.lastPathComponent)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.execute(script, arguments: ["list"], limit: SourceLimit.listSeconds, capture: true)
                let items = result.flatMap { $0.status == 0 ? sourceItems(from: $0.output) : nil }
                if items == nil {
                    Log.app.notice("palette source \(name, privacy: .public) gave no list (\(result.map { "status \($0.status), \($0.output.count) bytes" } ?? "it did not start or took too long", privacy: .public))")
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Without an answer the rows it listed before are dropped: they may be gone.
                    var next = self.listings.filter { $0.script != script }
                    if let items { next.append(Listing(script: script, name: name, items: items)) }
                    next.sort { $0.name < $1.name }
                    if next != self.listings {
                        self.listings = next
                        then()
                    }
                    waiting -= 1
                    guard waiting == 0 else { return }
                    self.refreshing = false
                    self.refreshed = Date()
                    Log.app.info("palette sources: \(self.listings.map(\.items.count).reduce(0, +)) rows from \(self.listings.count) of \(scripts.count) sources in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                }
            }
        }
    }

    /// Forgets the rows: the setting was switched off.
    func clear() {
        listings = []
        refreshed = .distantPast
    }

    /// Hands a chosen row back to its source; `then` is called on the main thread with whether the
    /// source said it worked (it ended with status 0 in time).
    func run(_ script: URL, arg: String, then: @escaping (Bool) -> Void) {
        let name = sourceName(file: script.lastPathComponent)
        // The file may have changed since it was listed: it is checked again before it is run.
        guard Self.scripts().contains(script) else {
            Log.app.notice("palette source \(name, privacy: .public) is no longer a file to run")
            return then(false)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.execute(script, arguments: ["run", arg], limit: SourceLimit.runSeconds, capture: false)
            DispatchQueue.main.async {
                if result?.status != 0 {
                    Log.app.notice("palette source \(name, privacy: .public) did not run the row (\(result.map { "status \($0.status)" } ?? "it did not start or took too long", privacy: .public))")
                }
                then(result?.status == 0)
            }
        }
    }

    /// Runs one file of the folder and waits for it, at most `limit` seconds. nil when it did not
    /// start or had to be stopped. With `capture`, what it printed (no more than a source may send).
    private static func execute(_ script: URL, arguments: [String], limit: TimeInterval, capture: Bool) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = sourceEnvironment(home: NSHomeDirectory(), user: NSUserName(), temporary: NSTemporaryDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = capture ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        let deadline = Date().addingTimeInterval(limit)
        let lock = NSLock()
        var output = Data()
        let ended = DispatchSemaphore(value: 0)
        if let pipe {
            // Read as it comes: a source that prints more than a pipe holds would wait for ever.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    ended.signal()
                    return
                }
                lock.lock()
                // One byte past the limit is kept, so that too much is told from just enough.
                if output.count <= SourceLimit.bytes { output.append(chunk.prefix(SourceLimit.bytes + 1 - output.count)) }
                lock.unlock()
            }
        }
        do {
            try process.run()
        } catch {
            pipe?.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        var inTime = false
        var closed = pipe == nil
        var exited: Date?
        while Date() < deadline {
            if !closed, ended.wait(timeout: .now()) == .success { closed = true }
            if !process.isRunning {
                if closed {
                    inTime = true
                    break
                }
                // The source ended and something it started still holds its output open (a tool
                // that leaves a server running): what was printed by then is all the source said.
                if let exited {
                    if Date().timeIntervalSince(exited) > 0.2 {
                        inTime = true
                        break
                    }
                } else {
                    exited = Date()
                }
            }
            usleep(5_000)
        }
        pipe?.fileHandleForReading.readabilityHandler = nil
        guard inTime else {
            if process.isRunning { process.terminate() }
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return (process.terminationStatus, output)
    }
}
