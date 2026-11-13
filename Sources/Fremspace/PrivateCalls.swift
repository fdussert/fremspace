import ApplicationServices
import Darwin
import FremspaceCore

/// The private calls of macOS that Fremspace reaches by name (`PrivateCall`), looked up when the
/// app runs, like the SkyLight ones beside them. Each is nil when this macOS does not have it:
/// what uses it then does less, and `missing` is what the status and the Status page say.
enum PrivateCalls {
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias WindowOfElement = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias DockNotification = @convention(c) (CFString, Int32) -> Int32
    typealias KeyboardClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias KeyboardCopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    typealias KeyboardSetProperty = @convention(c) (AnyObject, CFString, AnyObject) -> DarwinBoolean

    static let mainConnectionID = find(.mainConnection, as: MainConnectionID.self)
    static let copyManagedDisplaySpaces = find(.managedDisplaySpaces, as: CopyManagedDisplaySpaces.self)
    static let copySpacesForWindows = find(.spacesForWindows, as: CopySpacesForWindows.self)
    static let windowOfElement = find(.windowOfElement, as: WindowOfElement.self)
    static let processForPID = find(.processForPID, as: ProcessForPID.self)
    static let dockNotification = find(.dockNotification, as: DockNotification.self)
    static let keyboardClient = find(.keyboardClient, as: KeyboardClient.self)
    static let keyboardCopyProperty = find(.keyboardCopyProperty, as: KeyboardCopyProperty.self)
    static let keyboardSetProperty = find(.keyboardSetProperty, as: KeyboardSetProperty.self)

    /// The calls that are not on this macOS.
    static let missing: [PrivateCall] = PrivateCall.allCases.filter { address($0) == nil }

    /// Among every library the app has loaded (`RTLD_DEFAULT`): these come with CoreGraphics,
    /// ApplicationServices and IOKit, which the app links.
    private static func address(_ call: PrivateCall) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), call.rawValue)
    }

    private static func find<T>(_ call: PrivateCall, as type: T.Type) -> T? {
        address(call).map { unsafeBitCast($0, to: type) }
    }
}
