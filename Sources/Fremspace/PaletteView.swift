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
                PaletteMap(model: model)
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
        .accessibilityLabel([row.item.title, row.item.subtitle, row.tag].filter { !$0.isEmpty }.joined(separator: ", "))
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
/// list.
struct PaletteMap: View {
    @ObservedObject var model: PaletteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.map) { display in
                HStack(spacing: 10) {
                    Text(display.name)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(width: 104, alignment: .leading)
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
                .frame(height: Palette.mapRowHeight)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
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
        field.placeholderString = "A window, an app, a desktop, a command"
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
