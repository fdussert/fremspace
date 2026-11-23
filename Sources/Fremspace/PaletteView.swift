import AppKit
import SwiftUI
import FremspaceCore

enum PaletteHost {
    static func view(_ model: PaletteModel) -> NSView {
        NSHostingView(rootView: PaletteView(model: model))
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel

    private var hasMap: Bool { Palette.mapHeight(model) > 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: MenuBarIcon.image(.brand))
                    .foregroundStyle(.secondary)
                PaletteField(model: model)
            }
            .padding(.horizontal, 18)
            .frame(height: Palette.fieldHeight)
            if hasMap {
                Divider()
                PaletteMap(model: model, width: Palette.width(model))
                    .frame(height: Palette.mapHeight(model))
            }
            if !model.rows.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    list.frame(width: Palette.listWidth)
                    if model.showsPreviews {
                        Divider()
                        PalettePreview(row: model.rows.indices.contains(model.selected) ? model.rows[model.selected] : nil)
                    }
                }
                .frame(height: Palette.listHeight(model))
            } else if !model.query.isEmpty || model.desktop != nil {
                Divider()
                Text(model.query.isEmpty ? "No window on this desktop. Return shows it." : "Nothing by that name")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
            }
        }
        .frame(width: Palette.width(model), height: Palette.height(model), alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        PaletteRowView(row: row, selected: index == model.selected && !model.inMap)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.inMap = false
                                model.onChoose(index)
                            }
                    }
                }
                .padding(6)
            }
            .frame(height: Palette.listHeight(model))
            .onChange(of: model.selected) { index in proxy.scrollTo(index) }
        }
    }
}

private struct PaletteRowView: View {
    let row: PaletteRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let icon = row.icon {
                    if icon.isTemplate {
                        Image(nsImage: icon).resizable().scaledToFit().padding(5)
                    } else {
                        Image(nsImage: icon).resizable().scaledToFit()
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.item.title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !row.item.subtitle.isEmpty {
                    Text(row.item.subtitle).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 8)
            if row.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9.5))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            if !row.tag.isEmpty {
                Text(row.tag).font(.system(size: 11.5)).lineLimit(1).fixedSize()
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Palette.rowHeight)
        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.item.title, row.item.subtitle, row.tag, row.pinned ? "pinned" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Next to the list when previews are on: the picture of the selected window, or the icon of what
/// has none (an app, a minimised window).
private struct PalettePreview: View {
    let row: PaletteRow?
    @ObservedObject private var previews = WindowPreviews.shared

    private var picture: NSImage? {
        guard let row, case .window(let id, _) = row.action else { return nil }
        return previews.images[id]
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let picture {
                Image(nsImage: picture).resizable().interpolation(.high).scaledToFit()
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.18)))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            } else if let icon = row?.icon, !icon.isTemplate {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 56, height: 56)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

/// The desktops of every display, drawn as their layout with the apps in the slots. The desktop
/// each display shows has its name in full ink; ⇥ or the arrow keys go through them and narrow the
/// list. In a panel of a given width (the palette) each display's desktops are a carousel; where
/// the panel takes the map's own width (under the notch) they stand side by side.
struct PaletteMap: View {
    @ObservedObject var model: PaletteModel
    /// The width the map has to fit in; nil when the panel is as wide as the map.
    var width: CGFloat?

    private static let margin: CGFloat = 18
    private static let nameWidth: CGFloat = 104
    private static let spacing: CGFloat = 10

    var body: some View {
        // One display needs no name: there is nothing to tell it from. (It was also the first
        // thing pushed out of sight when its desktops outgrew the panel.)
        let named = model.map.count > 1
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.map) { display in
                HStack(spacing: Self.spacing) {
                    if named {
                        Text(display.name)
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .frame(width: Self.nameWidth, alignment: .leading)
                    }
                    if let width {
                        PaletteCarousel(display: display, model: model,
                                        width: width - 2 * Self.margin - (named ? Self.nameWidth + Self.spacing : 0))
                    } else {
                        ForEach(display.desktops) { desktop in
                            PaletteTile(desktop: desktop, chosen: model.desktop == desktop.desktop)
                                .contentShape(Rectangle())
                                .onTapGesture { model.onPickDesktop(desktop.desktop) }
                                .onHover { inside in
                                    guard model.hoverSelects else { return }
                                    if inside { model.desktop = desktop.desktop } else if model.desktop == desktop.desktop { model.desktop = nil }
                                }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: Palette.mapRowHeight)
            }
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 8)
    }
}

/// The desktops of one display in a row that turns: the desktop the keyboard is on (else the one
/// the display shows) stands in the middle, flat and a little larger, and the others lean away on
/// both sides like the faces of a drum. A swipe or the arrow keys turn it. A few desktops that
/// fit with room to spare stand side by side in the middle instead: a drum of three is a gimmick.
private struct PaletteCarousel: View {
    let display: PaletteDisplay
    @ObservedObject var model: PaletteModel
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let spacing: CGFloat = 10
    private static let tileWidth = PaletteTile.size.width + 8
    private static let space = "palette-carousel"

    private var turns: Bool {
        let count = CGFloat(display.desktops.count)
        return count * Self.tileWidth + max(count - 1, 0) * Self.spacing > width * 0.75
    }

    /// The desktop that stands in the middle: the chosen one when it is on this display, the one
    /// shown when no desktop is chosen. nil: the row stays as it is (the choice is elsewhere).
    private var middle: String? {
        if let chosen = model.desktop { return display.desktops.first { $0.desktop == chosen }?.id }
        return display.desktops.first(where: \.shown)?.id
    }

    var body: some View {
        if turns {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(display.desktops) { desktop in
                            GeometryReader { geometry in
                                tile(desktop, at: geometry.frame(in: .named(Self.space)).midX)
                            }
                            .frame(width: Self.tileWidth, height: Palette.mapRowHeight)
                            .id(desktop.id)
                        }
                    }
                    // Room on both sides, so that the first and the last desktop can stand in the middle.
                    .padding(.horizontal, max((width - Self.tileWidth) / 2, 0))
                }
                .coordinateSpace(name: Self.space)
                .frame(width: width, height: Palette.mapRowHeight)
                // The row runs out under the edges instead of being cut by them.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                             .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .onAppear { if let middle { proxy.scrollTo(middle, anchor: .center) } }
                .onChange(of: model.openings) { _ in if let middle { proxy.scrollTo(middle, anchor: .center) } }
                .onChange(of: middle) { id in
                    guard let id else { return }
                    if reduceMotion {
                        proxy.scrollTo(id, anchor: .center)
                    } else {
                        withAnimation(.interpolatingSpring(stiffness: 190, damping: 24)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        } else {
            HStack(spacing: Self.spacing) {
                ForEach(display.desktops) { desktop in plain(desktop) }
            }
            .frame(width: width, height: Palette.mapRowHeight)
        }
    }

    private func plain(_ desktop: PaletteDesktop) -> some View {
        PaletteTile(desktop: desktop, chosen: model.desktop == desktop.desktop)
            .contentShape(Rectangle())
            .onTapGesture { model.onPickDesktop(desktop.desktop) }
    }

    /// A desktop of the drum, `x` being its middle in the row. How far it is from the middle of
    /// the row, squared, so that the three or four desktops around the middle stay nearly flat
    /// and readable and only the far ones lean.
    private func tile(_ desktop: PaletteDesktop, at x: CGFloat) -> some View {
        let offset = max(-1, min(1, (x - width / 2) / (width / 2)))
        let lean = offset * abs(offset)
        return plain(desktop)
            .frame(width: Self.tileWidth, height: Palette.mapRowHeight)
            .scaleEffect(1.06 - 0.2 * abs(lean))
            .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(-lean) * 46), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .opacity(1 - 0.45 * Double(abs(lean)))
    }
}

private struct PaletteTile: View {
    let desktop: PaletteDesktop
    let chosen: Bool
    @ObservedObject private var previews = WindowPreviews.shared

    static let size = CGSize(width: 84, height: 46)

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                if !desktop.loose.isEmpty {
                    HStack(spacing: -3) {
                        ForEach(Array(desktop.loose.enumerated()), id: \.offset) { _, icon in
                            Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                        }
                    }
                    .padding(3)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 2).padding(-3))
            Text(desktop.label)
                .font(.system(size: 11, weight: desktop.shown ? .semibold : .regular))
                .foregroundStyle(desktop.shown ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1).truncationMode(.tail)
                .frame(width: Self.size.width + 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(desktop.label), \(desktop.windows) window\(desktop.windows == 1 ? "" : "s")\(desktop.shown ? ", shown" : "")")
    }

    @ViewBuilder private var thumbnail: some View {
        if let slots = desktop.slots {
            GeometryReader { geometry in
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    let rect = frame(slot.rect, in: geometry.size)
                    let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    ZStack {
                        shape.fill(Color.primary.opacity(desktop.shown ? 0.16 : 0.09))
                        if let picture = slot.window.flatMap({ previews.images[$0] }) {
                            // The top left of a window is what tells it from another.
                            Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                                .clipShape(shape)
                            if let icon = slot.icon, min(rect.width, rect.height) >= 20 {
                                Image(nsImage: icon).resizable().frame(width: 11, height: 11)
                                    .frame(width: rect.width - 4, height: rect.height - 4, alignment: .bottomLeading)
                            }
                        } else if let icon = slot.icon {
                            let side = max(8, min(18, min(rect.width, rect.height) - 4))
                            Image(nsImage: icon).resizable().frame(width: side, height: side)
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(desktop.shown ? 0.4 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }

    /// The slot in the thumbnail, half a gap off every inner side.
    private func frame(_ unit: UnitRect, in size: CGSize) -> CGRect {
        let gap: CGFloat = 2
        let x0 = CGFloat(unit.x) * size.width, x1 = CGFloat(unit.x + unit.w) * size.width
        let y0 = CGFloat(unit.y) * size.height, y1 = CGFloat(unit.y + unit.h) * size.height
        let left = x0 <= 0.5 ? 0 : x0 + gap / 2, right = x1 >= size.width - 0.5 ? size.width : x1 - gap / 2
        let top = y0 <= 0.5 ? 0 : y0 + gap / 2, bottom = y1 >= size.height - 0.5 ? size.height : y1 - gap / 2
        return CGRect(x: left, y: top, width: max(2, right - left), height: max(2, bottom - top))
    }
}

/// The palette's field: an AppKit text field, for the keys a list needs (arrows, Return, Escape,
/// Tab) while the text keeps the keyboard.
private struct PaletteField: NSViewRepresentable {
    @ObservedObject var model: PaletteModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = model.prompt
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search windows, apps, desktops and commands")
        model.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
        if field.placeholderString != model.prompt {
            field.placeholderString = model.prompt
            field.setAccessibilityLabel(model.prompt == PaletteModel.agentPrompt
                                        ? "Search windows, apps, desktops, commands and agent sessions"
                                        : "Search windows, apps, desktops and commands")
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let model: PaletteModel

        init(_ model: PaletteModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
            model.onQuery()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): model.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): model.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): model.onChoose(model.selected)
            case #selector(NSResponder.cancelOperation(_:)): model.onClose()
            case #selector(NSResponder.insertTab(_:)): model.onDesktop(true)
            case #selector(NSResponder.insertBacktab(_:)): model.onDesktop(false)
            case #selector(NSResponder.moveLeft(_:)): return model.onSide(-1)
            case #selector(NSResponder.moveRight(_:)): return model.onSide(1)
            default: return false
            }
            return true
        }
    }
}
