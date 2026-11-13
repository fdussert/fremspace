import os

/// Unified logging: `log stream --predicate 'subsystem == "dev.fremspace.app"'`.
enum Log {
    static let app = Logger(subsystem: "dev.fremspace.app", category: "app")
    static let windows = Logger(subsystem: "dev.fremspace.app", category: "windows")
    static let engine = Logger(subsystem: "dev.fremspace.app", category: "engine")
}
