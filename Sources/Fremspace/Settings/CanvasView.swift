import AppKit
import FremspaceCore
import SwiftUI

/// The configuration's displays; click one to edit it.
struct DisplayStrip: View {
    @ObservedObject var session: EditSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.configuration?.displays ?? [], id: \.identity) { display in
                    chip(display)
                }
            }
        }
    }

    private func chip(_ display: DisplaySpec) -> some View {
        let selected = display.identity == session.selection.display
        let connected = session.isConnected(display.identity)
        let builtIn = display.identity.name.localizedCaseInsensitiveContains("built-in")
        return Button {
            session.select(display: display.identity)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: display.ignored ? "eye.slash" : builtIn ? "laptopcomputer" : "display")
                    .font(.system(size: 15))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.displayName).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                    Text(display.ignored ? "Ignored" : connected ? counted(display.spaces.count, "desktop") : "Not connected")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1))
            .opacity(connected || selected ? 1 : 0.7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(connected ? (display.label.isEmpty ? display.identity.name : "\(display.displayName): \(display.identity.name)")
              : "\(display.displayName) is not connected: its layouts are kept and can be edited")
    }
}

/// The desktops of the selected display, by position (full-screen Spaces are not counted). A tab is
/// dragged by its body to reorder: it follows the pointer and the others make room, as in a browser.
struct DesktopTabs: View {
    @ObservedObject var session: EditSession
    /// The tab being dragged and how far the pointer took it.
    @State private var drag: (index: Int, translation: CGFloat)?
    /// The tabs where they rest, in the row's coordinates.
    @State private var frames: [Int: CGRect] = [:]
    @State private var hovered: Int?

    private static let spacing: CGFloat = 4

    var body: some View {
        if let display = session.displaySpec, !display.ignored {
            let preview = self.preview(count: display.spaces.count)
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(display.spaces.indices, id: \.self) { i in
                            tab(i, display.spaces[i], count: display.spaces.count, preview: preview)
                        }
                        Button { session.addDesktop() } label: {
                            Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Add a desktop to this display's configuration")
                    }
                    .coordinateSpace(name: "desktopTabs")
                    .onPreferenceChange(TabFrames.self) { frames = $0 }
                    // Room for the lifted tab's shadow.
                    .padding(.vertical, 3)
                }
                missingDesktops(display)
            }
        }
    }

    /// The row as it is drawn while a tab is dragged.
    private func preview(count: Int) -> ReorderPreview? {
        guard let drag, count > 1 else { return nil }
        let widths = (0..<count).compactMap { frames[$0]?.width }
        guard widths.count == count else { return nil }
        return reorderPreview(widths: widths, spacing: Self.spacing, dragged: drag.index, translation: drag.translation)
    }

    private func tab(_ i: Int, _ space: SpaceSpec, count: Int, preview: ReorderPreview?) -> some View {
        let selected = i == session.selection.desktop
        let lifted = drag?.index == i
        let movable = count > 1
        let shape = RoundedRectangle(cornerRadius: 6)
        // A plain view with a tap and a drag, not a Button: a Button swallows the drag.
        return HStack(spacing: 6) {
            if movable {
                Grip().opacity(lifted || hovered == i ? 0.85 : 0.35)
            }
            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Text(space.label.isEmpty ? "Untitled" : space.label).fontWeight(selected ? .semibold : .regular)
            if space.layout == nil {
                Text("free").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.leading, movable ? 7 : 10).padding(.trailing, 10).padding(.vertical, 5)
        .background(shape.fill(selected || lifted ? Color.primary.opacity(0.13) : hovered == i ? Color.primary.opacity(0.06) : Color.clear))
        // Opaque under the lifted tab, so the tabs it passes over do not show through.
        .background(shape.fill(lifted ? Color(NSColor.windowBackgroundColor) : Color.clear))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(lifted ? 0.9 : 0), lineWidth: 1.5))
        .shadow(color: .black.opacity(lifted ? 0.3 : 0), radius: 5, y: 2)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TabFrames.self, value: [i: proxy.frame(in: .named("desktopTabs"))])
        })
        .contentShape(Rectangle())
        .offset(x: lifted ? preview?.offset ?? 0 : preview?.shifts[i] ?? 0)
        .zIndex(lifted ? 1 : 0)
        // The others slide aside; the lifted tab follows the pointer as it is.
        .animation(lifted ? nil : .easeOut(duration: 0.16), value: preview?.shifts[i] ?? 0)
        .onTapGesture { session.select(desktop: i) }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("desktopTabs"))
            .onChanged { value in
                guard movable else { return }
                if drag == nil { NSCursor.closedHand.push() }
                drag = (i, value.translation.width)
            }
            .onEnded { _ in drop(count: count) })
        .onHover { inside in
            guard movable else { return }
            hovered = inside ? i : (hovered == i ? nil : hovered)
            // Not while a tab is dragged: the closed hand stays.
            if drag == nil { (inside ? NSCursor.openHand : NSCursor.arrow).set() }
        }
        .help(movable ? "Drag to reorder. On save, the windows of each desktop move with it." : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Move left") { session.moveDesktop(from: i, to: i - 1) }
        .accessibilityAction(named: "Move right") { session.moveDesktop(from: i, to: i + 1) }
        .contextMenu {
            Button("Move left") { session.moveDesktop(from: i, to: i - 1) }.disabled(i == 0)
            Button("Move right") { session.moveDesktop(from: i, to: i + 1) }.disabled(i >= count - 1)
            SwiftUI.Divider()
            Button("Remove from the configuration") { session.removeDesktop(at: i) }
                .disabled(count <= 1)
        }
    }

    /// The tab is let go: it slides into the place it made, then the order changes under it.
    private func drop(count: Int) {
        guard let drag else { return }
        NSCursor.pop()
        guard let preview = preview(count: count), preview.target != drag.index else {
            withAnimation(.easeOut(duration: 0.16)) { self.drag = nil }
            return
        }
        withAnimation(.easeOut(duration: 0.12)) { self.drag = (drag.index, preview.snap) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            // In one step and without animation: the tabs are already where the new order puts them.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // An undo or another display in the meantime: the tab that was dragged may be gone.
                guard let spaces = session.displaySpec?.spaces, spaces.indices.contains(drag.index),
                      spaces.indices.contains(preview.target) else {
                    self.drag = nil
                    return
                }
                let label = spaces[drag.index].label
                session.moveDesktop(from: drag.index, to: preview.target)
                self.drag = nil
                session.status = Status(kind: .info, text: "\u{201C}\(label.isEmpty ? "Untitled" : label)\u{201D} is now desktop \(preview.target + 1). On save, the windows of each desktop move with it.")
            }
        }
    }

    /// The display has fewer desktops than the configuration asks for. Adding them acts on the Mac at
    /// once (Mission Control opens), so it is offered only for what runs: the saved file of the
    /// configuration in use, and through the engine, which stops moving windows meanwhile. Desktops
    /// that exist only in unsaved changes, or in a configuration that is not in use, are said, not added.
    @ViewBuilder
    private func missingDesktops(_ display: DisplaySpec) -> some View {
        if let present = session.desktopCounts[display.identity], present < display.spaces.count,
           session.isConnected(display.identity) {
            let active = session.configuration.map(session.isActive) ?? false
            let addable = active ? max(0, (session.savedDesktopCount(on: display.identity) ?? 0) - present) : 0
            HStack(spacing: 8) {
                Image(systemName: Status.Kind.warning.symbol).foregroundColor(.orange)
                Text("This display has \(counted(present, "desktop")); \(display.spaces.count) are configured.")
                if addable > 0 {
                    Button("Add \(counted(addable, "desktop"))") {
                        let added = session.engine.addMissingDesktops()
                        session.refreshEnvironment()
                        session.status = added
                            ? Status(kind: .success, text: "Desktops added.")
                            : Status(kind: .error, text: "Could not add them: use Mission Control (the + at the top right).")
                    }
                    .help("Opens Mission Control and adds the desktops the saved configuration lacks, on every display")
                }
                if addable < display.spaces.count - present {
                    Text(!active ? "macOS gets them when this configuration is in use."
                         : addable > 0 ? "The others after you save." : "Save, then add them here.")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }
}

/// Where each desktop tab rests in the row, for the reordering.
private struct TabFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Six dots: the handle of something that can be dragged to another place.
private struct Grip: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The selected desktop drawn to scale: its slots, draggable dividers that snap to clean fractions,
/// and its drawers. With a drawer selected, the drawer's own layout is edited the same way.
struct CanvasView: View {
    @ObservedObject var session: EditSession
    /// The divider being dragged, frozen at drag start: dividers re-sort as they move, so the view
    /// under the gesture may change identity mid-drag.
    @State private var dragged: CoreDivider?
    /// The rail the pointer is on: its drawer's zone lights up over the layout.
    @State private var railHover: DrawerEdge?
    @ObservedObject private var previews = WindowPreviews.shared

    /// The screen is drawn dark in both appearances, like a display that is switched on.
    static let screen = Color(red: 0.075, green: 0.08, blue: 0.095)

    var body: some View {
        let geometry = session.geometry(of: session.selection.display)
        let visible = geometry.visible
        let rails = session.displaySpec.map { !$0.ignored } ?? false
        VStack(alignment: .leading, spacing: 10) {
            header
            ZStack {
                Self.screen
                if session.displaySpec?.ignored == true {
                    placeholder("eye.slash", "Ignored display", "Fremspace never touches the windows on this display.")
                } else if session.spaceSpec == nil {
                    placeholder("rectangle.dashed", "No desktop", "Add a desktop with the + above.")
                } else if session.editedLayout == nil {
                    FreeDesktopStart(session: session, connected: geometry.connected)
                } else {
                    GeometryReader { proxy in
                        canvas(size: proxy.size, visible: visible)
                    }
                }
            }
            .aspectRatio(visible.width / max(visible.height, 1), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
            // The display's drawers, where they are: a rail on each side of the screen.
            .padding(.horizontal, rails ? DrawerRail.width + 6 : 0)
            .overlay(alignment: .leading) { if rails { DrawerRail(session: session, edge: .left, hover: $railHover) } }
            .overlay(alignment: .trailing) { if rails { DrawerRail(session: session, edge: .right, hover: $railHover) } }
            .frame(maxWidth: .infinity)
            footer(connected: geometry.connected)
        }
        .onAppear { session.refreshSlotWindows() }
        .onChange(of: session.selection) { _ in session.refreshSlotWindows() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let edge = session.selection.drawer {
                Button { session.editDrawer(nil) } label: {
                    Label(session.spaceSpec?.label ?? "Desktop", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .help("Back to the desktop's layout (Esc)")
                Text("\(edge == .left ? "Left" : "Right") drawer").font(.headline)
            } else {
                Text(session.spaceSpec?.label ?? "").font(.headline)
            }
            Spacer()
            // A free desktop offers the capture on the screen itself, where the layout will be.
            if session.selection.drawer == nil, session.spaceSpec?.layout != nil, session.displaySpec?.ignored != true {
                CaptureButton(session: session)
            }
        }
        .frame(minHeight: 24)
    }

    /// Under the screen: what can be done with the selected slot, or how to start.
    @ViewBuilder
    private func footer(connected: Bool) -> some View {
        HStack(spacing: 8) {
            if let id = session.selection.slot, session.editedLayout != nil {
                // With their names where there is room for them, their symbols alone in a narrow window.
                ViewThatFits(in: .horizontal) {
                    slotActions(id, named: true)
                    slotActions(id, named: false)
                }
            } else if session.editedLayout != nil {
                Text("Click a slot to set it up. Drag the handles between slots to resize them.")
                    .font(.callout).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            // The size of a connected display is in the inspector; only the stand-in needs a word here.
            if !connected {
                Text("Not connected: drawn as 16:10").font(.subheadline).foregroundColor(.secondary)
            }
        }
        .frame(minHeight: 24)
    }

    private func slotActions(_ id: String, named: Bool) -> some View {
        HStack(spacing: 8) {
            Button { session.split(slot: id, along: .vertical) } label: {
                action("Split left | right", "rectangle.split.2x1", named: named)
            }
            .disabled(!session.canSplitSelected(.vertical))
            .help(named ? "" : "Split left | right")
            Button { session.split(slot: id, along: .horizontal) } label: {
                action("Split top / bottom", "rectangle.split.1x2", named: named)
            }
            .disabled(!session.canSplitSelected(.horizontal))
            .help(named ? "" : "Split top / bottom")
            Button(role: .destructive) { session.remove(slot: id) } label: {
                action("Remove", "trash", named: named)
            }
            // ⌘⌫ is the Layout menu's: there it is off while a text field has the keyboard, where the
            // same keys delete to the start of the line.
            .disabled((session.editedLayout?.slots.count ?? 0) <= 1)
            .help("Remove this slot; a neighbour takes its place (⌘⌫)")
        }
        .fixedSize()
    }

    @ViewBuilder
    private func action(_ title: String, _ symbol: String, named: Bool) -> some View {
        if named {
            Label(title, systemImage: symbol)
        } else {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light))
            Text(title).font(.headline)
            Text(detail).font(.callout).opacity(0.7)
        }
        .foregroundColor(.white.opacity(0.85))
        .multilineTextAlignment(.center)
        .padding(16)
    }

    private func rect(_ r: UnitRect, in c: UnitRect, size: CGSize) -> CGRect {
        CGRect(x: (c.x + r.x * c.w) * size.width, y: (c.y + r.y * c.h) * size.height,
               width: r.w * c.w * size.width, height: r.h * c.h * size.height)
    }

    private static let whole = UnitRect(x: 0, y: 0, w: 1, h: 1)

    @ViewBuilder
    private func canvas(size: CGSize, visible: CGRect) -> some View {
        let layout = session.editedLayout ?? CoreLayout(slots: [])
        let c = session.editedContainer
        let space = session.spaceSpec
        let editingDrawer = session.selection.drawer != nil
        let pictured = session.picturedSlots
        ZStack(alignment: .topLeading) {
            // A click on the empty screen deselects.
            Color.clear.contentShape(Rectangle()).onTapGesture { session.selection.slot = nil }
            // The desktop's layout, dimmed while a drawer is edited.
            if editingDrawer, let base = space?.layout {
                ForEach(base.slots, id: \.id) { slot in
                    let r = rect(slot.rect, in: Self.whole, size: size)
                    RoundedRectangle(cornerRadius: 6).fill(AppIcons.tint(slot.rule.bundleID).opacity(0.22))
                        .frame(width: max(r.width - 6, 1), height: max(r.height - 6, 1)).offset(x: r.minX + 3, y: r.minY + 3)
                        .allowsHitTesting(false)
                }
                let zone = rect(Self.whole, in: c, size: size)
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))
                    .frame(width: zone.width, height: zone.height).offset(x: zone.minX, y: zone.minY)
                    .allowsHitTesting(false)
            }
            ForEach(layout.slots, id: \.id) { slot in
                let r = rect(slot.rect, in: c, size: size)
                SlotTile(slot: slot, isDrawer: editingDrawer, isFocus: space.map { focusSlots($0).contains { $0.id == slot.id } } ?? false,
                         selected: session.selection.slot == slot.id,
                         picture: pictured.contains(slot.id) ? session.slotWindows[slot.id].flatMap { previews.images[$0] } : nil)
                    .frame(width: max(r.width - 6, 1), height: max(r.height - 6, 1))
                    .offset(x: r.minX + 3, y: r.minY + 3)
                    .onTapGesture { session.selection.slot = slot.id }
                    .contextMenu {
                        Button("Split left | right") { session.selection.slot = slot.id; session.split(slot: slot.id, along: .vertical) }
                            .disabled(!canSplit(layout, slot: slot.id, along: .vertical, length: CGFloat(c.w) * visible.width))
                        Button("Split top / bottom") { session.selection.slot = slot.id; session.split(slot: slot.id, along: .horizontal) }
                            .disabled(!canSplit(layout, slot: slot.id, along: .horizontal, length: CGFloat(c.h) * visible.height))
                        SwiftUI.Divider()
                        Button("Remove") { session.remove(slot: slot.id) }
                            .disabled(layout.slots.count <= 1)
                    }
            }
            // How far each drawer comes over the layout (not while one is edited).
            if !editingDrawer {
                ForEach(session.displaySpec?.drawers ?? [], id: \.edge) { drawer in
                    let zone = UnitRect(x: drawer.edge == .left ? 0 : 1 - drawer.size, y: 0, w: drawer.size, h: 1)
                    let r = rect(Self.whole, in: zone, size: size)
                    DrawerZone(edge: drawer.edge, lit: railHover == drawer.edge)
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
            }
            ForEach(dividers(layout), id: \.stableID) { divider in
                handle(divider, layout: layout, container: c, size: size, visible: visible)
            }
        }
        .coordinateSpace(name: "canvas")
    }

    private func handle(_ divider: CoreDivider, layout: CoreLayout, container c: UnitRect, size: CGSize, visible: CGRect) -> some View {
        let involved = layout.slots.filter { divider.before.contains($0.id) || divider.after.contains($0.id) }
        let vertical = divider.axis == .vertical
        let spanStart = involved.map { vertical ? $0.rect.y : $0.rect.x }.min() ?? 0
        let spanEnd = involved.map { vertical ? $0.rect.y + $0.rect.h : $0.rect.x + $0.rect.w }.max() ?? 1
        let along = vertical
            ? rect(UnitRect(x: divider.position, y: spanStart, w: 0, h: spanEnd - spanStart), in: c, size: size)
            : rect(UnitRect(x: spanStart, y: divider.position, w: spanEnd - spanStart, h: 0), in: c, size: size)
        let length = vertical ? CGFloat(c.w) * visible.width : CGFloat(c.h) * visible.height
        return DividerHandle(vertical: vertical, span: vertical ? along.height : along.width, active: dragged?.stableID == divider.stableID)
            .offset(x: vertical ? along.minX - DividerHandle.thickness / 2 : along.minX,
                    y: vertical ? along.minY : along.minY - DividerHandle.thickness / 2)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas")).onChanged { value in
                if dragged == nil {
                    dragged = divider
                    session.checkpoint()
                }
                guard let frozen = dragged, let current = session.editedLayout else { return }
                let fraction = frozen.axis == .vertical
                    ? (Double(value.location.x / size.width) - c.x) / c.w
                    : (Double(value.location.y / size.height) - c.y) / c.h
                let moved = move(current, divider: frozen, to: fraction, length: length)
                if moved != current { session.setEditedLayout(moved) }
            }.onEnded { _ in
                dragged = nil
                session.checkpoint()
            })
    }
}

/// The grab area between slots: a thin pill that brightens under the pointer, with a resize cursor.
struct DividerHandle: View {
    static let thickness: CGFloat = 22
    let vertical: Bool
    let span: CGFloat
    let active: Bool
    @State private var hovering = false

    var body: some View {
        let lit = hovering || active
        Capsule().fill(Color.white.opacity(lit ? 1 : 0.55))
            .shadow(color: .black.opacity(0.5), radius: 1.5)
            .frame(width: vertical ? (lit ? 5 : 4) : min(span * 0.4, 72), height: vertical ? min(span * 0.4, 72) : (lit ? 5 : 4))
            .frame(width: vertical ? Self.thickness : span, height: vertical ? span : Self.thickness)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .onDisappear {
                // The handle can go away under the pointer (a slot removed): keep the cursor stack balanced.
                if hovering { NSCursor.pop() }
            }
            .help("Drag to resize; it snaps to clean fractions")
    }
}

/// One side of the screen: the display's drawer on that edge (click to edit it), or the place to add
/// one. Always there, on every desktop, because a drawer belongs to the display.
struct DrawerRail: View {
    @ObservedObject var session: EditSession
    let edge: DrawerEdge
    /// The rail under the pointer, shared with the screen, which lights that drawer's zone.
    @Binding var hover: DrawerEdge?

    static let width: CGFloat = 24

    var body: some View {
        let drawer = session.displaySpec?.drawers.first { $0.edge == edge }
        let editing = session.selection.drawer == edge
        let shape = RoundedRectangle(cornerRadius: 7)
        Button {
            if drawer == nil {
                session.addDrawer(edge)
            } else {
                session.editDrawer(editing ? nil : edge)
            }
        } label: {
            // With the apps that live in the drawer when the rail is long enough for them.
            ViewThatFits(in: .vertical) {
                column(drawer, apps: true)
                column(drawer, apps: false)
            }
            .frame(width: Self.width).frame(maxHeight: .infinity)
            .foregroundColor(editing ? .white : drawer != nil ? .accentColor : .secondary)
            .background(shape.fill(editing ? Color.accentColor : drawer != nil ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(drawer == nil ? Color.primary.opacity(0.28) : Color.accentColor.opacity(0.6),
                                        style: StrokeStyle(lineWidth: 1, dash: drawer == nil ? [4, 3] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hover = edge } else if hover == edge { hover = nil }
        }
        .help(drawer == nil ? "Add a \(edge.rawValue) drawer to this display: a panel of windows that slides over the \(edge.rawValue) edge"
              : editing ? "Back to the desktop's layout" : "Edit the \(edge.rawValue) drawer of this display")
    }

    private func column(_ drawer: DrawerSpec?, apps: Bool) -> some View {
        let name = edge == .left ? "Left drawer" : "Right drawer"
        let rules = drawer?.layout.slots.flatMap(\.rules) ?? []
        return VStack(spacing: 8) {
            Image(systemName: drawer == nil ? "plus" : edge == .left ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 12, weight: .medium))
            // Read from the screen outwards, like the spine of a book lying next to it.
            Text(drawer.map { "\(name)  \(fractionLabel($0.size))" } ?? name)
                .font(.caption.weight(.medium)).lineLimit(1).fixedSize()
                .rotationEffect(.degrees(edge == .left ? -90 : 90))
                .frame(width: 16, height: 110)
            if apps, !rules.isEmpty {
                VStack(spacing: 4) {
                    // A handful: the rail says a drawer has apps, the drawer's own screen says which.
                    ForEach(Array(rules.prefix(4).enumerated()), id: \.offset) { _, rule in
                        if let icon = AppIcons.icon(rule.bundleID) {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// How far a drawer comes over the desktop's layout: a bracket in the gutters at the top and the
/// bottom of the screen, in the rail's colour, and the whole zone while the pointer is on the rail.
/// Not a line across the tiles: it would strike through their titles and vanish on a tile of the
/// accent's hue. And nothing white or dashed, which on this screen mean "selected" and "to fill in".
struct DrawerZone: View {
    let edge: DrawerEdge
    let lit: Bool

    var body: some View {
        let inner: Alignment = edge == .left ? .trailing : .leading
        Rectangle().fill(Color.accentColor.opacity(lit ? 0.32 : 0))
            .overlay(alignment: .top) { bar }
            .overlay(alignment: .bottom) { bar }
            .overlay(alignment: inner) {
                // The inner edge itself only while the zone is lit.
                Rectangle().fill(Color.accentColor).frame(width: 2).opacity(lit ? 1 : 0)
            }
            .overlay(alignment: edge == .left ? .topTrailing : .topLeading) { tick }
            .overlay(alignment: edge == .left ? .bottomTrailing : .bottomLeading) { tick }
            .animation(.easeOut(duration: 0.12), value: lit)
    }

    /// As high as the gutter between the screen's edge and the tiles.
    private var bar: some View {
        Rectangle().fill(Color.accentColor).frame(height: 3)
    }

    /// Where the drawer stops; short enough to stay above the tiles' titles.
    private var tick: some View {
        Rectangle().fill(Color.accentColor).frame(width: 2, height: 7)
    }
}

/// A free desktop on the screen: what it is, and the two ways to give it a layout.
struct FreeDesktopStart: View {
    @ObservedObject var session: EditSession
    /// Whether the display is there: without it there is no window to capture.
    let connected: Bool

    var body: some View {
        // A short, wide display leaves no room for the picture and the second line.
        ViewThatFits(in: .vertical) {
            card(full: true)
            card(full: false)
        }
        // The screen is dark in both appearances: its buttons are too.
        .environment(\.colorScheme, .dark)
    }

    private func card(full: Bool) -> some View {
        let ink = Color.white.opacity(0.9)
        return VStack(spacing: 10) {
            if full {
                Image(systemName: "hand.raised").font(.system(size: 26, weight: .light)).foregroundColor(ink)
            }
            Text("Free desktop").font(.headline).foregroundColor(ink)
            HStack(spacing: 8) {
                Button("Capture this desktop") { session.captureDesktop() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected)
                Button("Make a layout") { session.makeLayout() }
            }
            VStack(spacing: 3) {
                Text(connected ? "Capture makes the layout from the windows this desktop shows now."
                     : "This display is not connected: there is no window to capture.")
                if full {
                    Text("Or leave it free: Fremspace does not touch the windows here.")
                }
            }
            .font(.callout).foregroundColor(ink.opacity(0.75))
        }
        .multilineTextAlignment(.center)
        .padding(14)
        .fixedSize()
    }
}

struct SlotTile: View {
    let slot: Slot
    let isDrawer: Bool
    let isFocus: Bool
    let selected: Bool
    /// The window in the slot now, when previews are on and the slot is as saved.
    var picture: NSImage?

    private var empty: Bool { !isDrawer && slot.rule.bundleID.isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        shape
            .fill(isDrawer ? Color(white: 0.42) : empty ? Color.white.opacity(0.06) : AppIcons.tint(slot.rule.bundleID))
            .overlay {
                if empty {
                    shape.strokeBorder(Color.orange.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                } else {
                    // A lighter top edge, so neighbouring tiles of the same app stay apart.
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .overlay {
                if let picture {
                    // Dimmed, so that the slot's name and apps stay what is read.
                    GeometryReader { geometry in
                        Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                            .overlay(Color.black.opacity(0.45))
                    }
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                GeometryReader { geometry in
                    content(tileFit(width: geometry.size.width, height: geometry.size.height,
                                    apps: apps.filter { AppIcons.icon($0.bundleID) != nil }.count, states: states.count))
                }
            }
            .overlay(shape.strokeBorder(Color.white, lineWidth: selected ? 2.5 : 0))
            .shadow(color: selected ? Color.white.opacity(0.35) : .clear, radius: 6)
            .contentShape(shape)
    }

    /// The title, then what fits of the size, the icons and the states (`tileFit`), each in its own
    /// band of the tile so that none is drawn over another.
    private func content(_ fit: TileFit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: TileMetrics.titleLine, maxHeight: TileMetrics.titleLine, alignment: .leading)
            if fit.size {
                Text(sizeLabel(width: slot.rect.w, height: slot.rect.h))
                    .font(.system(size: 11, weight: .medium).monospacedDigit()).opacity(0.9).lineLimit(1)
                    .frame(height: TileMetrics.sizeLine, alignment: .leading)
            }
            ZStack {
                if let side = fit.icon { icons(side: side) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, TileMetrics.iconGap)
            if fit.states { stateRow(words: fit.stateWords) }
        }
        .foregroundColor(empty ? .orange : .white)
        .padding(TileMetrics.padding)
    }

    /// The apps to draw: every rule of a layout slot, the real ones of a drawer slot.
    private var apps: [Rule] { isDrawer ? drawerApps(slot) : slot.rules }

    /// What is particular to the slot. An ordinary one (one app, locked) says nothing, so that a
    /// mark on a tile always means something; a lock on every tile meant nothing.
    private var states: [(symbol: String, word: String, help: String)] {
        var list: [(symbol: String, word: String, help: String)] = []
        if isFocus && !isDrawer {
            list.append(("arrow.up.left.and.arrow.down.right", "Focus", "Focus enlarges this slot"))
        }
        if !isDrawer && !slot.locked {
            list.append(("lock.open.fill", "Unlocked", "Not locked: its window can be moved and resized"))
        }
        if apps.count > 1 {
            list.append(("square.stack.fill", "\(apps.count) apps", "The windows of these apps stack in this slot"))
        }
        return list
    }

    private func stateRow(words: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                HStack(spacing: 3) {
                    Image(systemName: state.symbol).font(.system(size: 9, weight: .bold))
                    if words { Text(state.word).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize() }
                }
                .padding(.horizontal, words ? 7 : 5)
                .frame(height: TileMetrics.stateRow)
                .background(Capsule().fill(Color.black.opacity(0.38)))
                .help(state.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.word)
            }
        }
        .foregroundColor(.white)
    }

    private var title: String {
        if isDrawer {
            let apps = drawerApps(slot)
            return apps.isEmpty ? slot.id : apps.map { appName($0.bundleID) + ($0.profile.map { " – \($0)" } ?? "") }.joined(separator: " + ")
        }
        if empty { return "Choose an app" }
        return slot.rules.map { rule in appName(rule.bundleID) + (rule.profile.map { " – \($0)" } ?? "") }.joined(separator: " + ")
    }

    /// The icon of each app the slot takes, in a row, in the band the text leaves them.
    private func icons(side: CGFloat) -> some View {
        HStack(spacing: side / 5) {
            ForEach(Array(apps.enumerated()), id: \.offset) { _, rule in
                if let icon = AppIcons.icon(rule.bundleID) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// App icons by bundle id, cached (read from the installed app; nil when it is not installed), and
/// the tile colour drawn from each icon.
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]
    private static var tints: [String: Color] = [:]

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let icon = bundleID.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }

    /// The icon at menu size.
    static func small(_ bundleID: String) -> NSImage? {
        guard let icon = icon(bundleID), let copy = icon.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    /// The colour of the app's tile: the dominant hue of its icon, calmed down so that white text
    /// reads on it. An app without an icon, or with a grey one, gets a stable hue from its bundle id.
    static func tint(_ bundleID: String) -> Color {
        if let cached = tints[bundleID] { return cached }
        let color: Color
        if bundleID.isEmpty {
            color = Color(white: 0.4)
        } else {
            let hue = icon(bundleID).flatMap(dominantHue) ?? fallbackHue(bundleID)
            color = Color(hue: hue, saturation: 0.58, brightness: 0.56)
        }
        tints[bundleID] = color
        return color
    }

    private static func fallbackHue(_ bundleID: String) -> Double {
        let hash = bundleID.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Double(hash % 360) / 360
    }

    /// The most present hue among the icon's coloured pixels (0...1), nil when the icon is grey.
    private static func dominantHue(_ icon: NSImage) -> Double? {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep), let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var total = 0.0
        for i in 0..<(side * side) {
            let alpha = Double(data[i * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            // Premultiplied components.
            let r = Double(data[i * 4]) / 255 / alpha, g = Double(data[i * 4 + 1]) / 255 / alpha, b = Double(data[i * 4 + 2]) / 255 / alpha
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            guard high > 0.2, delta > 0.15 else { continue }
            var hue: Double
            if high == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) } else if high == g { hue = (b - r) / delta + 2 } else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
            let w = (delta / high) * high
            weight[min(bins - 1, Int(hue * Double(bins)))] += w
            total += w
        }
        // A handful of coloured pixels on a grey icon is not its colour.
        guard total > Double(side * side) * 0.04, let best = weight.indices.max(by: { weight[$0] < weight[$1] }) else { return nil }
        return (Double(best) + 0.5) / Double(bins)
    }
}
