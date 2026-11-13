/// Whether sending windows to another desktop works on this macOS: a private SkyLight operation
/// that a macOS update may break. Unavailable when the operation is not on this macOS at all
/// (`isPresent` false: no send is ever tried, so nothing else would say it), and after `threshold`
/// failed sends in a row (each send already retries once); available again after any success, and
/// tried again when the owner re-applies the layouts.
public struct MoverHealth {
    public let threshold: Int
    /// The operation exists on this macOS.
    public let isPresent: Bool
    public private(set) var isAvailable: Bool
    private var failures = 0

    public init(threshold: Int = 2, present: Bool = true) {
        self.threshold = threshold
        isPresent = present
        isAvailable = present
    }

    public mutating func record(success: Bool) {
        guard isPresent else { return }
        if success {
            failures = 0
            isAvailable = true
        } else {
            failures += 1
            if failures >= threshold { isAvailable = false }
        }
    }

    /// The owner re-applies the layouts: sends are tried again, and stop again if they still fail.
    /// Without this only a send by hand that succeeded, or a restart, brought automatic sends back.
    public mutating func retry() {
        failures = 0
        isAvailable = isPresent
    }
}
