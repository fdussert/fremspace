import XCTest
@testable import FremspaceCore

final class ConfigStoreTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("config.json") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fremspace-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func exampleConfig() throws -> Config {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("Resources/example-config.json"))
        return try JSONDecoder().decode(Config.self, from: data)
    }

    private func config(named name: String) -> Config {
        Config(version: Config.currentVersion,
               configurations: [Configuration(id: UUID(), name: name, displays: [])])
    }

    func testRoundTrip() throws {
        let example = try exampleConfig()
        XCTAssertFalse(example.configurations.isEmpty)
        let store = ConfigStore(url: url)
        try store.save(example)
        let loaded = try store.load()
        XCTAssertEqual(loaded, example)
    }

    func testSaveKeepsBackup() throws {
        let store = ConfigStore(url: url)
        let a = config(named: "A"), b = config(named: "B")
        try store.save(a)
        try store.save(b)
        let loaded = try store.load()
        XCTAssertEqual(loaded, b)
        let backup = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url.appendingPathExtension("bak")))
        XCTAssertEqual(backup, a)
    }

    func testAFileThatChangedIsToldFromOneThatIsGoneOrUnreadable() throws {
        let store = ConfigStore(url: url)
        let a = config(named: "A"), b = config(named: "B")
        // No file yet: an editor that read "no configuration" is where the file is.
        XCTAssertEqual(store.state(since: Config(configurations: [])), .same)
        try store.save(a)
        XCTAssertEqual(store.state(since: a), .same)
        try store.save(b)
        XCTAssertEqual(store.state(since: a), .changed)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.state(since: a), .missing)
        try Data("{ nope".utf8).write(to: url)
        guard case .unreadable = store.state(since: a) else { return XCTFail("a corrupt file is unreadable") }
    }

    func testSaveOverAFileThatCannotBeReadIsRefusedAndLeavesIt() throws {
        let store = ConfigStore(url: url)
        let a = config(named: "A")
        try store.save(a)
        let broken = Data("{ nope".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try store.save(config(named: "B"), expecting: a)) { error in
            XCTAssertEqual(error as? ConfigError, .changedOnDisk)
        }
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, broken)
    }

    func testNewerVersionIsRejectedWithoutOverwrite() throws {
        let bytes = Data(#"{"version":2,"configurations":[]}"#.utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try ConfigStore(url: url).load()) { error in
            XCTAssertEqual(error as? ConfigError, .newerVersion(2))
        }
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, bytes)
    }

    func testCorruptFileKeepsOriginal() throws {
        let bytes = Data("{not json".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try ConfigStore(url: url).load()) { error in
            guard case .corrupt? = error as? ConfigError else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, bytes)
    }

    func testMissingFileLoadsEmpty() throws {
        let loaded = try ConfigStore(url: url).load()
        XCTAssertEqual(loaded, Config(version: 1, configurations: []))
    }

    /// A desktop written by hand without `unmatched` (the drawer spec's sketch omits it) floats.
    func testDesktopWithoutUnmatchedFloats() throws {
        let spec = try JSONDecoder().decode(SpaceSpec.self, from: Data(#"{"label": "Browse"}"#.utf8))
        XCTAssertEqual(spec.unmatched, .float)
    }

    /// A display written by hand without `ignored` is a display Fremspace manages.
    func testDisplayWithoutIgnoredIsManaged() throws {
        let json = #"{"identity": {"vendor": 1, "model": 2, "serial": 3, "name": "Desk"}, "spaces": [{"label": "Code"}]}"#
        let spec = try JSONDecoder().decode(DisplaySpec.self, from: Data(json.utf8))
        XCTAssertFalse(spec.ignored)
        XCTAssertEqual(spec.spaces.map(\.label), ["Code"])
    }

    func testSaveRefusesWhenTheFileChangedSinceRead() throws {
        // I4: the editor read the file, then "Lock on this desktop" saved it: the editor's Save must
        // not write its stale copy over that change.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let read = Config(configurations: [])
        try store.save(read)
        let changed = Config(configurations: [Configuration(id: UUID(), name: "Locked", displays: [])])
        try store.save(changed, expecting: read)
        XCTAssertThrowsError(try store.save(Config(configurations: []), expecting: read)) { error in
            XCTAssertEqual(error as? ConfigError, .changedOnDisk)
        }
        let onDisk = try store.load()
        XCTAssertEqual(onDisk, changed)
    }
}
