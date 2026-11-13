import AppKit
import FremspaceCore
import SwiftUI

/// A desktop drawn small: its slots at their places, on the ground of the editor's screen. One
/// drawing for everything the Layouts page shows: the ready-made layouts (shapes alone), the
/// desktops kept (their apps' icons) and the desktops of a file seen before it is added (the names
/// of their apps, and what is not on this Mac).
struct LayoutMiniature: View {
    enum Content {
        /// Empty slots: a ready-made layout. The slot Focus enlarges is in the accent colour.
        case shapes
        /// The icon of each app, as the editor's tiles have it.
        case icons
        /// The name of each slot's app: a file from somebody else is read before it is trusted.
        case names
    }

    /// The desktop to draw; without a layout it is a free desktop.
    let desktop: SpaceSpec
    let content: Content
    /// Width over height of the display it is drawn for.
    var aspect: CGFloat = 1.6
    /// The drawers of its display: a bar on their edge.
    var drawers: [DrawerEdge] = []
    /// The apps that are not on this Mac.
    var missing: Set<String> = []
    /// What the picture shows, for who cannot see it ("Main and two: 3 slots, 2/3 and two halves").
    let spoken: String

    private static let orange = Color.orange

    var body: some View {
        GeometryReader { geometry in
            // The room a drawer's bar takes on its edge.
            let left: CGFloat = drawers.contains(.left) ? 7 : 0, right: CGFloat = drawers.contains(.right) ? 7 : 0
            let area = CGRect(x: 3 + left, y: 3, width: max(geometry.size.width - 6 - left - right, 1), height: max(geometry.size.height - 6, 1))
            ZStack(alignment: .topLeading) {
                CanvasView.screen
                if let layout = desktop.layout {
                    let focus = Set(focusSlots(desktop).map(\.id))
                    ForEach(layout.slots, id: \.id) { slot in
                        let width = max(CGFloat(slot.rect.w) * area.width - 2, 1), height = max(CGFloat(slot.rect.h) * area.height - 2, 1)
                        tile(slot, focus: focus.contains(slot.id), size: CGSize(width: width, height: height))
                            .frame(width: width, height: height)
                            .offset(x: area.minX + CGFloat(slot.rect.x) * area.width + 1, y: area.minY + CGFloat(slot.rect.y) * area.height + 1)
                    }
                } else {
                    free(in: area)
                }
                if left > 0 { bar.offset(x: 3, y: 4).frame(height: max(geometry.size.height - 8, 1)) }
                if right > 0 { bar.offset(x: geometry.size.width - 7, y: 4).frame(height: max(geometry.size.height - 8, 1)) }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isImage)
    }

    /// A drawer, in the colour the editor gives its rail.
    private var bar: some View {
        Capsule().fill(Color.accentColor).frame(width: 4)
    }

    /// A free desktop: no slot, and it says so where there is room.
    private func free(in area: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if area.width >= 130 {
                Text("No slots: windows float").font(.system(size: 10)).foregroundColor(.white.opacity(0.65))
            } else {
                Image(systemName: "hand.raised").font(.system(size: 12)).foregroundColor(.white.opacity(0.65))
            }
        }
        .frame(width: area.width, height: area.height)
        .offset(x: area.minX, y: area.minY)
    }

    @ViewBuilder
    private func tile(_ slot: Slot, focus: Bool, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        let apps = slot.rules.map(\.bundleID).filter { !$0.isEmpty }
        let away = apps.contains { missing.contains($0) }
        switch content {
        case .shapes:
            shape.fill(focus ? Color.accentColor : Color.white.opacity(0.18))
                .overlay(alignment: .bottomLeading) { if focus, size.width >= 26, size.height >= 22 { focusMark(word: false).padding(3) } }
        case .icons:
            ground(shape, apps: apps, away: false)
                .overlay { icons(apps, size: size) }
                .overlay(alignment: .bottomLeading) { if focus, size.width >= 34, size.height >= 34 { focusMark(word: false).padding(3) } }
        case .names:
            ground(shape, apps: apps, away: away)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(apps.isEmpty ? "No app" : apps.map(appName).joined(separator: " + "))
                            .font(.system(size: 10, weight: .semibold)).lineLimit(size.height >= 44 ? 2 : 1)
                        if away, size.height >= 30 { Text("not on this Mac").font(.system(size: 9)).lineLimit(1) }
                    }
                    .foregroundColor(away || apps.isEmpty ? Self.orange : .white)
                    .padding(4)
                }
                .overlay(alignment: .bottomLeading) {
                    if focus, size.height >= (away ? 52 : 40) { focusMark(word: size.width >= 60).padding(3) }
                }
        }
    }

    /// The ground of the editor's tiles, with the app's colour along the top; a slot without an
    /// app, or whose app is not here, is outlined as the editor outlines a slot to fill in.
    private func ground(_ shape: RoundedRectangle, apps: [String], away: Bool) -> some View {
        shape.fill(apps.isEmpty ? Color.white.opacity(0.06) : away ? Self.orange.opacity(0.14) : SlotTile.ground)
            .overlay {
                if let hue = apps.first.flatMap({ AppIcons.hue($0) }), !away {
                    shape.fill(hue).mask(alignment: .top) { Rectangle().frame(height: 2) }
                }
            }
            .overlay {
                if apps.isEmpty || away {
                    shape.strokeBorder(Self.orange.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
    }

    /// The icons of a slot's apps in a row; an app that is not on this Mac has a mark in its place.
    @ViewBuilder
    private func icons(_ apps: [String], size: CGSize) -> some View {
        let shown = Array(apps.prefix(3))
        let side = min(22, size.height * 0.6, (size.width - 6) / (CGFloat(max(shown.count, 1)) * 1.15))
        if side >= 9 {
            HStack(spacing: side * 0.15) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, app in
                    if let icon = AppIcons.icon(app) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: side, height: side)
                    } else {
                        Image(systemName: "questionmark.app.dashed").font(.system(size: side * 0.8)).foregroundColor(Self.orange)
                            .frame(width: side, height: side)
                    }
                }
            }
        }
    }

    /// Focus as the editor's tiles say it: the two arrows, with the word where there is room.
    private func focusMark(word: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 7, weight: .bold))
            if word { Text("Focus").font(.system(size: 9, weight: .semibold)) }
        }
        .foregroundColor(.white)
        .padding(.horizontal, word ? 5 : 3).frame(height: 13)
        .background(Capsule().fill(Color.black.opacity(0.4)))
    }
}

/// A layout file that holds more than one desktop, drawn as a pile: its first desktop on top.
struct DeskMiniature: View {
    let layout: SharedLayout
    let spoken: String

    var body: some View {
        let first = layout.displays.first
        let sheet = RoundedRectangle(cornerRadius: 6)
        ZStack {
            sheet.fill(Color.primary.opacity(0.07)).overlay(sheet.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                .padding(.leading, 14).padding(.bottom, 12)
            sheet.fill(Color.primary.opacity(0.1)).overlay(sheet.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                .padding(.horizontal, 7).padding(.vertical, 6)
            LayoutMiniature(desktop: first?.desktops.first ?? SpaceSpec(label: ""), content: .icons,
                            aspect: CGFloat(first?.aspect ?? 1.6), drawers: first?.drawers.map(\.edge) ?? [], spoken: spoken)
                .padding(.trailing, 14).padding(.top, 12)
        }
        .aspectRatio(1.6, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isImage)
    }
}

/// A desktop drawn as the editor draws it, with the editor's own tiles, not to be edited: what a
/// layout would make of it, before it is used.
struct DesktopDrawing: View {
    let desktop: SpaceSpec
    /// Width over height of the display it would be on.
    let aspect: CGFloat
    let spoken: String

    var body: some View {
        ZStack {
            CanvasView.screen
            GeometryReader { proxy in
                let focus = Set(focusSlots(desktop).map(\.id))
                ZStack(alignment: .topLeading) {
                    ForEach(desktop.layout?.slots ?? [], id: \.id) { slot in
                        SlotTile(slot: slot, isDrawer: false, isFocus: focus.contains(slot.id), selected: false)
                            .frame(width: max(CGFloat(slot.rect.w) * proxy.size.width - 4, 1), height: max(CGFloat(slot.rect.h) * proxy.size.height - 4, 1))
                            .offset(x: CGFloat(slot.rect.x) * proxy.size.width + 2, y: CGFloat(slot.rect.y) * proxy.size.height + 2)
                    }
                }
            }
            .padding(2)
            if desktop.layout == nil {
                Text("Free desktop").font(.callout).foregroundColor(.white.opacity(0.7))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isImage)
    }
}
