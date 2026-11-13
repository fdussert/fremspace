import AppKit
import ObjectiveC

/// Sends a window to another desktop with SkyLight's bridged window-management operation, which
/// works with SIP on (spike step 6, docs/spikes/2026-11-spaces.md: 43/44 on macOS 27.0.1). Private
/// and resolved at runtime: when the classes or selectors are missing, `isPresent` is false and
/// Fremspace arranges windows where they are, as before.
///
/// Asynchronous only: the synchronous variant is reported to crash. Every send is checked with the
/// window's Space list, and submitted a second time when the window did not arrive.
enum SpaceMover {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
    private static let performSelector = NSSelectorFromString("performAsynchronousBridgedWindowManagementOperation:")
    private static let transactionSelector = NSSelectorFromString("performWindowManagementBridgeTransactionUsingBlock:")
    /// How long to wait for the window to arrive after each submission, and how often to look.
    static let wait: TimeInterval = 1
    static let pollInterval: TimeInterval = 0.1
    /// For a window the owner is waiting to see (an open drawer following its display): the move
    /// itself takes a few milliseconds, and each one waited on top is a desktop shown without it.
    static let eagerPollInterval: TimeInterval = 0.015

    private static var operationClass: NSObject.Type? {
        _ = skyLight
        return NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") as? NSObject.Type
    }

    private static var bridgeClass: NSObject.Type? {
        _ = skyLight
        return NSClassFromString("SLSWindowManagementFallbackBridge") as? NSObject.Type
    }

    /// The classes and selectors of spike step 6 exist on this macOS.
    static var isPresent: Bool {
        guard let operationClass, let bridgeClass else { return false }
        return class_getInstanceMethod(operationClass, initSelector) != nil
            && class_getInstanceMethod(bridgeClass, performSelector) != nil
            && class_getInstanceMethod(bridgeClass, transactionSelector) != nil
    }

    /// Sends window `id` to Space `sid` (a `ManagedSpaceID`). `completion(true)` once the window is
    /// on that Space only, `completion(false)` when it is not there after two submissions. Main
    /// thread.
    static func send(_ id: UInt32, toSpace sid: UInt64, lookEvery interval: TimeInterval = pollInterval,
                     completion: @escaping (Bool) -> Void) {
        guard isPresent else { return completion(false) }
        if Spaces.spaceIDs(ofWindow: id) == [sid] { return completion(true) }
        submit(id, sid)
        poll(id, sid, every: interval, until: Date().addingTimeInterval(wait)) { arrived in
            if arrived { return completion(true) }
            Log.engine.notice("window \(id) did not reach space \(sid); submitting again")
            submit(id, sid)
            poll(id, sid, every: interval, until: Date().addingTimeInterval(wait), completion)
        }
    }

    private static func poll(_ id: UInt32, _ sid: UInt64, every interval: TimeInterval, until deadline: Date,
                             _ done: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            if Spaces.spaceIDs(ofWindow: id) == [sid] { return done(true) }
            if Date() >= deadline { return done(false) }
            poll(id, sid, every: interval, until: deadline, done)
        }
    }

    private static func submit(_ id: UInt32, _ sid: UInt64) {
        guard let operationClass, let bridgeClass,
              let imp = class_getMethodImplementation(operationClass, initSelector) else { return }
        typealias InitFunction = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        // As in the spike: alloc, then the init implementation called directly (its arguments are not
        // objects, so `perform` cannot pass them). The operation object is not released (a few bytes
        // per send), which is what ran 43 times without a crash.
        guard let allocated = operationClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let operation = unsafeBitCast(imp, to: InitFunction.self)(allocated, initSelector,
                                                                        [NSNumber(value: id)] as NSArray, sid) else {
            Log.engine.error("window \(id): the move operation could not be created")
            return
        }
        let bridge = bridgeClass.init()
        let block: @convention(block) () -> Void = { _ = bridge.perform(performSelector, with: operation) }
        _ = bridge.perform(transactionSelector, with: block)
    }
}
