import AppKit
import FremspaceCore
import ScreenCaptureKit

/// Pictures of the windows, for the palette, the maps of desktops and the editor. A general setting,
/// off unless switched on, because it needs a second permission: Screen Recording. The pictures are
/// small, live in memory only and are dropped when the setting goes off.
///
/// A window of another desktop has no picture through the public calls of macOS 13, so the window
/// server is asked first (the call every switcher uses, resolved at run time: when it is missing,
/// nothing breaks), then ScreenCaptureKit on macOS 14 and later for what it did not give.
final class WindowPreviews: ObservableObject {
    static let shared = WindowPreviews()
    /// The longest side of a picture, in pixels: enough for the palette's pane on a Retina display.
    static let longest: CGFloat = 640

    /// The pictures, by window id. Empty while the setting is off or macOS does not allow them.
    @Published private(set) var images: [UInt32: NSImage] = [:]
    /// The setting is on and macOS allows pictures of windows.
    private(set) var isOn = false
    private var enabled = false
    private var ledger = PreviewLedger()
    private var pending: Set<UInt32> = []
    private let queue = DispatchQueue(label: "dev.fremspace.previews", qos: .userInitiated)

    /// macOS lets Fremspace take pictures of other apps' windows.
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system's request the first time. macOS writes the app down as denied at once
    /// (seen on macOS 27), which is what lists it under Screen Recording for the owner to switch
    /// on. The list names the entry after whichever bundle carries the identifier: a second app
    /// with Fremspace's identifier on the Mac shows there under its own name.
    static func request() {
        guard !allowed else { return }
        let asked = CGRequestScreenCaptureAccess()
        Log.app.notice("previews: Screen Recording asked for (allowed: \(asked, privacy: .public))")
    }

    /// Opens the Screen Recording list of System Settings, with Fremspace asked for first so that
    /// it is in the list.
    static func openSettings() {
        request()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The general setting, as saved. On and not allowed yet: macOS is asked once per launch (it
    /// shows its request the first time only), so that Fremspace is in the list to switch on.
    func set(enabled: Bool) {
        self.enabled = enabled
        if !check(), enabled, !askedThisLaunch {
            askedThisLaunch = true
            Self.request()
        }
    }
    private var askedThisLaunch = false

    /// Reads the permission again (it can be given while Fremspace runs). True when pictures are on.
    @discardableResult
    func check() -> Bool {
        let on = enabled && Self.allowed
        if on != isOn {
            isOn = on
            Log.app.notice("previews: \(on ? "on" : self.enabled ? "wanted, Screen Recording not allowed" : "off", privacy: .public)")
        }
        if !on {
            if !images.isEmpty { images = [:] }
            ledger.forgetAll()
        }
        return on
    }

    /// Drops the picture of a window that was closed. The palette drops those of every window
    /// that is gone each time it opens (`keep`); for someone who uses the map under the notch
    /// and the editor and never the palette, pictures of about a megabyte each piled up until
    /// Fremspace quit.
    func forget(_ id: UInt32) {
        // One being taken now is not kept when it arrives.
        pending.remove(id)
        ledger.forget(id)
        if images[id] != nil { images[id] = nil }
    }

    /// Drops the pictures of the windows that are gone.
    func keep(_ alive: Set<UInt32>) {
        for id in ledger.keep(alive) where images[id] != nil { images[id] = nil }
    }

    /// Takes the pictures of these windows that are missing or no longer fresh, the first given
    /// first, off the main thread. `images` changes as they arrive.
    func refresh(_ ids: [UInt32]) {
        // Behind the lock screen every window is the lock screen.
        guard isOn, !Engine.sessionIsLocked else { return }
        let now = Date()
        let due = ledger.due(ids, now: now).filter { !pending.contains($0) }
        guard !due.isEmpty else { return }
        pending.formUnion(due)
        queue.async { [weak self] in
            var missing: [UInt32] = []
            for id in due {
                if let image = Self.capture(id) {
                    DispatchQueue.main.async { self?.store(image, for: id) }
                } else {
                    missing.append(id)
                }
            }
            Self.capturePublic(missing) { found in
                guard let self else { return }
                for (id, image) in found { self.store(image, for: id) }
                // A window without picture (minimised, or refused) is not asked again at once.
                for id in missing where found[id] == nil {
                    self.pending.remove(id)
                    self.ledger.took(id, at: Date())
                }
                let got = due.count - missing.count + found.count
                Log.app.info("previews: \(got) of \(due.count) windows pictured\(found.isEmpty ? "" : ", \(found.count) through ScreenCaptureKit", privacy: .public)")
            }
        }
    }

    /// Keeps a picture. Main thread.
    func store(_ image: NSImage, for id: UInt32) {
        // Switched off, or its window closed, while it was being taken.
        guard pending.remove(id) != nil, enabled else { return }
        ledger.took(id, at: Date())
        images[id] = image
    }

    // MARK: - The window server

    private typealias CaptureFunction = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?

    /// `SLSHWCaptureWindowList`: the pictures of a list of windows, on whatever desktop they are.
    private static let captureFunction: CaptureFunction? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(skyLight, "SLSHWCaptureWindowList") ?? dlsym(skyLight, "CGSHWCaptureWindowList") else {
            Log.app.notice("previews: the window server's capture call is missing on this macOS")
            return nil
        }
        return unsafeBitCast(symbol, to: CaptureFunction.self)
    }()

    /// The whole window whatever covers it or clips it, at one pixel per point.
    private static let captureOptions: UInt32 = 1 << 11 | 1 << 9

    private static func capture(_ id: UInt32) -> NSImage? {
        guard let captureFunction, let connection = Spaces.connection else { return nil }
        var window = id
        guard let list = captureFunction(connection, &window, 1, captureOptions)?.takeRetainedValue() as? [CGImage],
              let image = list.first, image.width > 1, image.height > 1 else { return nil }
        return scaled(image)
    }

    private static func scaled(_ image: CGImage) -> NSImage? {
        let size = previewSize(of: CGSize(width: image.width, height: image.height), longest: longest)
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }

    // MARK: - ScreenCaptureKit

    /// The pictures of the windows the window server gave none for. `done` runs on the main thread.
    private static func capturePublic(_ ids: [UInt32], done: @escaping ([UInt32: NSImage]) -> Void) {
        guard !ids.isEmpty, #available(macOS 14.0, *) else { return DispatchQueue.main.async { done([:]) } }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            let wanted = Set(ids)
            let group = DispatchGroup()
            let lock = NSLock()
            var found: [UInt32: NSImage] = [:]
            for window in content?.windows ?? [] where wanted.contains(window.windowID) {
                let size = previewSize(of: window.frame.size, longest: longest)
                guard size.width >= 1, size.height >= 1 else { continue }
                let configuration = SCStreamConfiguration()
                configuration.width = Int(size.width)
                configuration.height = Int(size.height)
                configuration.showsCursor = false
                group.enter()
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                 configuration: configuration) { image, _ in
                    if let image {
                        lock.lock()
                        found[window.windowID] = NSImage(cgImage: image, size: size)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { done(found) }
        }
    }
}
