import AppKit
import Carbon.HIToolbox
import FremspaceCore
import SwiftUI

/// What hangs at the top of the displays: for a moment the name of the desktop a display just
/// changed to, and, on a display with a notch, the map of desktops while the pointer rests on the
/// notch. Out of a notch it is black and flush with the top edge, like the notch growing; on a
/// display without one it is a pill under the menu bar. Nothing here takes the keyboard.
final class NotchController {
    /// How long a desktop's name stays.
    static let stay: TimeInterval = 1.2
    /// How long the pointer rests on the notch before the map opens: crossing it does not open it.
    static let dwell: TimeInterval = 0.12
    /// How long after the pointer left the map it closes.
    static let leave: TimeInterval = 0.25
    /// Above the menu bar, which the notch is part of.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    private let engine: Engine
    private let palette: Palette
    /// The desktop each display showed at the last change.
    private var shown: [DisplayIdentity: Int] = [:]
    private var banners: [DisplayIdentity: (panel: NSPanel, hide: DispatchWorkItem?)] = [:]
    /// Sits on the notch and tells when the pointer comes onto it.
    private var hoverPanel: NSPanel?
    /// The display with a notch, when the map is on.
    private var notched: NotchGeometry?
    private var mapPanel: NSPanel?
    private let mapModel = PaletteModel()
    private var opening: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    /// The arrow keys, Return and Escape while the map is open; the app in front keeps the others.
    private let keys = KeyGrab()
    private var screenToken: NSObjectProtocol?

    init(engine: Engine, palette: Palette) {
        self.engine = engine
        self.palette = palette
        mapModel.hoverSelects = true
        mapModel.onPickDesktop = { [weak self] desktop in
            self?.closeMap()
            self?.palette.show(desktop)
        }
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
    }

    static func geometry(_ screen: NSScreen) -> NotchGeometry {
        NotchGeometry(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                      left: screen.auxiliaryTopLeftArea?.width, right: screen.auxiliaryTopRightArea?.width,
                      menuBar: screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// The settings or the displays changed.
    func refresh() {
        let connected = Set(Displays.connected().map(\.identity))
        shown = shown.filter { connected.contains($0.key) }.merging(Spaces.current()) { _, new in new }
        placeHover()
    }

    // MARK: - The name of a desktop

    /// A display shows another desktop: its name hangs at the top of that display for a moment.
    func desktopChanged() {
        let current = Spaces.current()
        let changed = changedDesktops(from: shown, to: current)
        // A display on a full-screen Space is absent: what it showed before is kept.
        shown.merge(current) { _, new in new }
        let mapOpen = mapPanel?.isVisible ?? false
        if mapOpen { mapModel.map = palette.currentMap() }
        guard engine.desktopNames, !changed.isEmpty else { return }
        let counts = Desktops.counts()
        for display in changed {
            guard let index = current[display], let screen = Displays.screen(of: display) else { continue }
            let geometry = Self.geometry(screen)
            // The open map hangs there and already says it.
            if mapOpen, geometry.notch != nil { continue }
            let label = engine.desktopSpec(SpaceKey(display: display, spaceIndex: index))?.label
            show(desktopBanner(label: label, index: index, count: counts[display] ?? 0), on: display, geometry)
        }
    }

    private func show(_ banner: DesktopBanner, on display: DisplayIdentity, _ geometry: NotchGeometry) {
        let label = BannerLabel(banner: banner)
        let frame = geometry.hanging(content: NSHostingView(rootView: label).fittingSize)
        var entry = banners[display] ?? (makePanel(clickThrough: true), nil)
        let panel = entry.panel
        // A new view each time: it grows out of the notch again.
        panel.contentView = NSHostingView(rootView: Hanging(notch: geometry.notch?.size, radius: 14) { label })
        panel.hasShadow = geometry.notch == nil
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        entry.hide?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                // Another change may have shown it again meanwhile.
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            })
        }
        entry.hide = work
        banners[display] = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stay, execute: work)
    }

    // MARK: - The map under the notch

    /// Puts the hover panel on the notch of the display that has one, or takes it away.
    private func placeHover() {
        let geometry = engine.notchMap ? NSScreen.screens.map(Self.geometry).first { $0.notch != nil } : nil
        guard let geometry, let notch = geometry.notch else {
            notched = nil
            opening?.cancel()
            hoverPanel?.orderOut(nil)
            closeMap()
            return
        }
        notched = geometry
        if hoverPanel == nil {
            let panel = makePanel(clickThrough: false)
            // The notch has no pixels: black there shows nothing and catches the pointer.
            let view = HoverView()
            view.fill = .black
            view.onEnter = { [weak self] in self?.pointerOnNotch() }
            view.onExit = { [weak self] in self?.opening?.cancel() }
            panel.contentView = view
            hoverPanel = panel
        }
        hoverPanel?.setFrame(notch, display: true)
        hoverPanel?.orderFrontRegardless()
    }

    private func pointerOnNotch() {
        opening?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.openMap() }
        opening = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
    }

    private func openMap() {
        // A button held down: something is being dragged along the top, the map is not asked for.
        guard engine.notchMap, let geometry = notched, let notch = geometry.notch,
              geometry.isOnNotch(NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0 else { return }
        let map = palette.currentMap()
        // One desktop in all, or no configuration applied: nothing to show.
        guard !map.isEmpty else { return }
        closing?.cancel()
        mapModel.map = map
        mapModel.desktop = nil
        let content = NotchMapContent(model: mapModel)
        let frame = geometry.hanging(content: NSHostingView(rootView: content).fittingSize)
        let panel = mapPanel ?? makePanel(clickThrough: false)
        mapPanel = panel
        let container = HoverView(frame: NSRect(origin: .zero, size: frame.size))
        container.onEnter = { [weak self] in self?.closing?.cancel() }
        container.onExit = { [weak self] in self?.pointerLeftMap() }
        let host = ClickHostingView(rootView: Hanging(notch: notch.size, radius: 18) { content })
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        keys.start { [weak self] keyCode in self?.mapKey(keyCode) ?? false }
        Log.app.info("notch: map of \(map.reduce(0) { $0 + $1.desktops.count }) desktops")
    }

    /// A key while the map is open. True when the map took it.
    private func mapKey(_ keyCode: Int) -> Bool {
        guard let panel = mapPanel, panel.isVisible else {
            keys.stop()
            return false
        }
        // The pointer went away and the panel was not told: the keys are the app's again.
        let pointer = NSEvent.mouseLocation
        guard panel.frame.insetBy(dx: -4, dy: -4).contains(pointer) || notched?.isOnNotch(pointer) == true else {
            closeMap()
            return false
        }
        // The first arrow starts from the desktop the display with the notch shows.
        let row = mapModel.map.firstIndex { display in
            display.desktops.first.flatMap { Displays.screen(of: $0.desktop.display) }?.frame == notched?.screen
        } ?? 0
        switch keyCode {
        case kVK_LeftArrow: mapModel.step(dx: -1, dy: 0, from: row)
        case kVK_RightArrow: mapModel.step(dx: 1, dy: 0, from: row)
        case kVK_UpArrow: mapModel.step(dx: 0, dy: -1, from: row)
        case kVK_DownArrow: mapModel.step(dx: 0, dy: 1, from: row)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let desktop = mapModel.desktop else { return false }
            closeMap()
            palette.show(desktop)
        case kVK_Escape:
            closeMap()
        default:
            return false
        }
        return true
    }

    private func pointerLeftMap() {
        closing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Back inside meanwhile (the tracking area missed it): it stays.
            guard let self, let panel = self.mapPanel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.closeMap()
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leave, execute: work)
    }

    private func closeMap() {
        keys.stop()
        closing?.cancel()
        guard let panel = mapPanel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func makePanel(clickThrough: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.level
        panel.ignoresMouseEvents = clickThrough
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

/// Tells when the pointer comes onto it and leaves it, whatever app is active.
private final class HoverView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var fill: NSColor?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }

    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        fill.setFill()
        dirtyRect.fill()
    }
}

/// Its content answers the first click: the panel it is in never becomes the key window.
private final class ClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A rectangle flush with the top edge, its two lower corners rounded.
struct NotchShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Content hanging at the top of a display. With a notch: black, as wide and high as the view, the
/// content at the bottom (under the notch); it grows out of the notch when it appears. Without:
/// the content on a pill.
struct Hanging<Content: View>: View {
    let notch: CGSize?
    let radius: CGFloat
    let content: Content
    @State private var grown = false

    init(notch: CGSize?, radius: CGFloat, @ViewBuilder content: () -> Content) {
        self.notch = notch
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        if let notch {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    NotchShape(radius: radius).fill(Color.black)
                        .frame(width: grown ? proxy.size.width : notch.width, height: grown ? proxy.size.height : notch.height)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        content
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .opacity(grown ? 1 : 0)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .environment(\.colorScheme, .dark)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { grown = true }
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The name of a desktop and one dot per desktop of its display, the one shown filled.
struct BannerLabel: View {
    let banner: DesktopBanner

    var body: some View {
        VStack(spacing: 6) {
            Text(banner.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if banner.count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<min(banner.count, 16), id: \.self) { i in
                        Circle().fill(Color.primary.opacity(i == banner.index ? 0.95 : 0.3)).frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Desktop \(banner.index + 1) of \(banner.count): \(banner.label)")
    }
}

/// The palette's map, as wide as its desktops.
struct NotchMapContent: View {
    @ObservedObject var model: PaletteModel

    var body: some View {
        PaletteMap(model: model).fixedSize().padding(.top, 2).padding(.bottom, 4)
    }
}
