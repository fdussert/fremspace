import AppKit
import FremspaceCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings of what is selected, one thing at a time: the slot when there is one, else the desktop
/// (or the drawer being edited) and its display. Stacked, the three ran to a thousand points and the
/// desktop's and the display's settings were out of sight whenever a slot was selected.
struct InspectorView: View {
    @ObservedObject var session: EditSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if session.displaySpec?.ignored != true, session.spaceSpec != nil {
                    if let slot = session.selectedSlot {
                        back("Desktop and display settings")
                        SlotInspector(session: session, slot: slot)
                    } else if let slotID = session.selection.slot, session.selection.drawer != nil {
                        back("Drawer and display settings")
                        DrawerSlotInspector(session: session, slotID: slotID)
                    } else {
                        if let edge = session.selection.drawer {
                            DrawerInspector(session: session, edge: edge)
                        } else {
                            DesktopInspector(session: session)
                        }
                        DisplayInspector(session: session).padding(.top, 6)
                    }
                } else if session.displaySpec != nil {
                    DisplayInspector(session: session)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The way back from a slot: the slots cover the screen, so there is no empty place to click.
    /// At the top, where it stays in view however long the slot's settings are.
    private func back(_ title: String) -> some View {
        Button { session.selection.slot = nil } label: {
            Label(title, systemImage: "chevron.left")
        }
        .buttonStyle(.link).font(.subheadline)
        .help("Deselects the slot")
    }
}

/// A group of the inspector: its controls on a card.
struct InspectorCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
    }
}

/// A titled group of the inspector.
struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
            InspectorCard { content }
        }
    }
}

/// What a setting does, under its name: one size everywhere, and never wider than a line one reads
/// without losing its start.
struct HelpText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.subheadline).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520, alignment: .leading)
    }
}

/// Beside the few switches that are not in the config file and so do not wait for Save. The rule
/// is the default and is said once; only the exceptions carry a mark.
struct AtOnceMark: View {
    var body: some View {
        Label("At once", systemImage: "bolt.fill")
            .font(.caption.weight(.semibold)).foregroundColor(.primary.opacity(0.75))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.09)))
            .fixedSize()
            .help("Acts as soon as you flip it, without waiting for Save")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Acts at once")
    }
}

/// The rest of an explanation, for who wants it: kept off the page, one click away. A word, not a
/// question mark beside the name: in the inspector the name and its switch leave no room for one.
struct MoreHelp: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button("More\u{2026}") { shown.toggle() }
            .buttonStyle(.link).font(.subheadline)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 320, alignment: .leading).padding(14)
            }
    }
}

/// A switch with its name and, under it, what it does.
struct SwitchRow: View {
    let title: String
    /// One or two lines; empty for a switch whose name says it all.
    let detail: String
    /// Not in the config file: the switch acts when flipped, without waiting for Save.
    var atOnce = false
    /// What the detail has no room for, behind "More…".
    var more: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    if atOnce { AtOnceMark() }
                }
                if !detail.isEmpty { HelpText(detail) }
                if let more { MoreHelp(text: more) }
            }
            Spacer(minLength: 4)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A caption above a control.
struct Field<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            content
        }
    }
}

/// Picks an app: those running, those the configuration already uses, or any app on disk.
struct AppMenu: View {
    let title: String
    let bundleID: String?
    let known: [String]
    let choose: (String) -> Void

    private var apps: [(name: String, id: String)] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap(\.bundleIdentifier)
        return Set(running + known).filter { !$0.isEmpty }.map { (appName($0), $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Menu {
            ForEach(apps, id: \.id) { app in
                Button { choose(app.id) } label: {
                    Label { Text(app.name) } icon: {
                        if let icon = AppIcons.small(app.id) { Image(nsImage: icon) }
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            SwiftUI.Divider()
            Button("Other…") { chooseFromDisk() }
        } label: {
            if let bundleID, !bundleID.isEmpty {
                Label { Text(appName(bundleID)) } icon: {
                    if let icon = AppIcons.small(bundleID) { Image(nsImage: icon) }
                }
                .labelStyle(.titleAndIcon)
            } else {
                Text(title)
            }
        }
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the app this slot takes"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        choose(id)
    }
}

struct SlotInspector: View {
    @ObservedObject var session: EditSession
    let slot: Slot
    @State private var showsBundleID = false

    private func update(_ change: @escaping (inout Slot) -> Void) {
        session.updateSpace { space in
            guard let i = space.layout?.slots.firstIndex(where: { $0.id == slot.id }) else { return }
            change(&space.layout!.slots[i])
        }
    }

    /// The apps the configurations already place somewhere: offered even when they are not running.
    private var configuredApps: [String] {
        session.config.configurations.flatMap(\.displays).flatMap(\.spaces)
            .flatMap { $0.layout?.slots ?? [] }.flatMap(\.rules).map(\.bundleID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            InspectorCard {
                apps
                profileField
                Field(slot.rules.count > 1 ? "Window title of \(appName(slot.rule.bundleID)) contains" : "Window title contains") {
                    TextField("Any window", text: Binding(
                        get: { slot.rule.titleContains ?? "" },
                        set: { text in update { $0.rule.titleContains = text.isEmpty ? nil : text } }))
                        .textFieldStyle(.roundedBorder)
                }
                SwiftUI.Divider()
                SwitchRow(title: "Locked", detail: "The window snaps back when it is moved or resized.",
                          isOn: Binding(get: { slot.locked }, set: { on in update { $0.locked = on } }))
                SwitchRow(title: "Focus enlarges this slot",
                          detail: "\(focusShortcut) gives it the whole display, and back.",
                          more: "With the keyboard in this slot, the Focus shortcut gives it the whole display; the same shortcut gives the display back. Any number of slots of a desktop can have it. From a window that is in none of them, the shortcut enlarges the one furthest left.",
                          isOn: Binding(
                            get: { session.spaceSpec.map { focusSlots($0).contains { $0.id == slot.id } } ?? false },
                            set: { on in
                                session.checkpoint()
                                session.updateSpace { $0 = settingFocus($0, slot: slot.id, on: on) }
                            }))
                SwitchRow(title: "Open at login", detail: "Restore opens the app when it is not running.",
                          isOn: Binding(get: { slot.launchAtLogin }, set: { on in update { $0.launchAtLogin = on } }))
                SwiftUI.Divider()
                sizeLine
                if let warning {
                    Label(warning, systemImage: Status.Kind.warning.symbol)
                        .labelStyle(StatusLabelStyle(color: .orange)).font(.callout)
                }
                toDrawer
                DisclosureGroup("App identifier", isExpanded: $showsBundleID) {
                    TextField("com.example.app", text: Binding(get: { slot.rule.bundleID }, set: { id in update { $0.rule.bundleID = id } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    /// The Focus shortcut as the owner set it, or its name when it has no key.
    private var focusShortcut: String {
        let label = session.shortcutLabel("focusToggle")
        return label == "no shortcut" ? "The Focus shortcut" : label
    }

    /// Which slot this is, in place of the word "Slot": its app, and the desktop and display it is on,
    /// now that their own settings are not under it.
    private var header: some View {
        let others = slot.rules.count - 1
        let name = slot.rule.bundleID.isEmpty ? "Empty slot" : appName(slot.rule.bundleID) + (others > 0 ? " and \(others) more" : "")
        let place = [session.spaceSpec?.label, session.displaySpec?.displayName].compactMap { $0 }.filter { !$0.isEmpty }
        return HStack(spacing: 10) {
            if let icon = AppIcons.icon(slot.rule.bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 32, height: 32)
            } else {
                Image(systemName: "rectangle.dashed").font(.system(size: 22, weight: .light)).foregroundColor(.orange)
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text((["Slot"] + place).joined(separator: " \u{00B7} ")).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The slot's apps as one list: the first is the one the slot is named after (its menu changes
    /// it), the others stack with it (also added by "Lock on this desktop" over the slot).
    private var apps: some View {
        Field("Apps") {
            AppMenu(title: "Choose an app\u{2026}", bundleID: slot.rule.bundleID, known: configuredApps) { id in
                session.checkpoint()
                update { slot in
                    slot.rule.bundleID = id
                    if !isTabbedBrowser(id) { slot.rule.profile = nil }
                }
            }
            ForEach(Array(slot.rules.dropFirst().enumerated()), id: \.offset) { offset, rule in
                HStack(spacing: 6) {
                    if let icon = AppIcons.small(rule.bundleID) { Image(nsImage: icon) }
                    Text(appName(rule.bundleID) + (rule.profile.map { " \u{2013} \($0)" } ?? "")).lineLimit(1)
                    Spacer()
                    Button {
                        session.checkpoint()
                        update { if $0.rules.indices.contains(offset + 1) { $0.rules.remove(at: offset + 1) } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Take \(appName(rule.bundleID)) out of this slot")
                }
            }
            AppMenu(title: "Add an app\u{2026}", bundleID: nil, known: configuredApps) { id in
                guard !slot.rules.contains(where: { $0.bundleID == id && $0.profile == nil && $0.titleContains == nil }) else { return }
                session.checkpoint()
                update { $0.rules.append(Rule(bundleID: id)) }
            }
            .disabled(slot.rule.bundleID.isEmpty)
            HelpText("Several windows here stack: \(session.shortcutLabel("stackNext")) goes through them, \(session.shortcutLabel("stackPrevious")) the other way.")
        }
    }

    @ViewBuilder
    private var profileField: some View {
        if isTabbedBrowser(slot.rule.bundleID) {
            // The profiles Fremspace has seen in this browser's window titles.
            let known = session.engine.knownProfiles(bundleID: slot.rule.bundleID)
            Field("Browser profile") {
                Picker("Browser profile", selection: Binding(
                    get: { slot.rule.profile ?? "" },
                    set: { name in update { $0.rule.profile = name.isEmpty ? nil : name } })) {
                    Text("Any profile").tag("")
                    ForEach(known, id: \.self) { Text($0).tag($0) }
                    if let current = slot.rule.profile, !known.contains(current) { Text(current).tag(current) }
                }
                .labelsHidden()
            }
        } else if let profile = slot.rule.profile {
            // A profile on a non-browser rule matches nothing: shown so it can be cleared.
            HStack {
                Text("Profile: \(profile)")
                Spacer()
                Button("Clear") { update { $0.rule.profile = nil } }
            }
        }
    }

    /// "Move to left / right drawer": for an app that should live in a drawer rather than in the
    /// layout. Last, with what acts on the slot, not among its properties: it takes the slot away.
    @ViewBuilder
    private var toDrawer: some View {
        let edges = (session.displaySpec?.drawers ?? []).filter { !$0.layout.slots.isEmpty }.map(\.edge)
        if !slot.rule.bundleID.isEmpty {
            if edges.isEmpty {
                HelpText("To keep this app in a drawer instead, add one with the rails beside the screen.")
            } else {
                HStack(spacing: 6) {
                    ForEach(edges, id: \.self) { edge in
                        Button { session.moveToDrawer(slot: slot.id, edge: edge) } label: {
                            Label("Move to \(edge.rawValue) drawer", systemImage: edge == .left ? "sidebar.left" : "sidebar.right")
                        }
                        .help("Takes \(appName(slot.rule.bundleID)) out of this layout and gives it to the \(edge.rawValue) drawer of this display")
                    }
                }
            }
        }
    }

    private var frame: CGRect? {
        guard let layout = session.spaceSpec?.layout else { return nil }
        let visible = session.geometry(of: session.selection.display).visible
        return slotFrames(layout: layout, focus: nil, visible: visible, gap: Engine.gap)[slot.id]
    }

    private var sizeLine: some View {
        HStack {
            Text(sizeWords(width: slot.rect.w, height: slot.rect.h))
            Spacer()
            if let frame { Text("\(Int(frame.width)) × \(Int(frame.height)) pt").monospacedDigit() }
        }
        .font(.callout).foregroundColor(.secondary)
    }

    /// "Outlook needs at least 770 × 650; this slot is 744 × 441", from sizes the engine learned.
    private var warning: String? {
        guard let layout = session.spaceSpec?.layout else { return nil }
        let visible = session.geometry(of: session.selection.display).visible
        let frames = slotFrames(layout: layout, focus: nil, visible: visible, gap: Engine.gap)
        guard let minimum = tooSmall(frames, layout: layout, minimums: session.engine.minimumSizes)[slot.id],
              let frame = frames[slot.id] else { return nil }
        return "\(appName(slot.rule.bundleID)) needs at least \(Int(minimum.width)) × \(Int(minimum.height)); this slot is \(Int(frame.width)) × \(Int(frame.height))."
    }
}

/// A slot of a drawer: the apps whose windows go to it by themselves. Any other window can still be
/// sent to it by hand.
struct DrawerSlotInspector: View {
    @ObservedObject var session: EditSession
    let slotID: String

    private var edge: DrawerEdge? { session.selection.drawer }

    private var slot: DrawerSlot? {
        session.displaySpec?.drawers.first { $0.edge == edge }?.layout.slots.first { $0.id == slotID }
    }

    /// The apps the configurations already use: offered even when they are not running.
    private var configuredApps: [String] {
        let displays = session.config.configurations.flatMap(\.displays)
        return displays.flatMap(\.spaces).flatMap { $0.layout?.slots ?? [] }.flatMap(\.rules).map(\.bundleID)
            + displays.flatMap(\.drawers).flatMap(\.layout.slots).flatMap(\.rules).map(\.bundleID)
    }

    private func update(_ change: (inout DrawerSlot) -> Void) {
        guard let edge else { return }
        session.updateDrawerSlot(edge, slotID, change)
    }

    var body: some View {
        InspectorSection("Drawer slot") {
            if let slot, let edge {
                Field("Apps") {
                    ForEach(Array(slot.rules.enumerated()), id: \.offset) { offset, rule in
                        row(offset, rule)
                    }
                    AppMenu(title: slot.rules.isEmpty ? "Choose an app…" : "Add an app…", bundleID: nil, known: configuredApps) { id in
                        guard !slot.rules.contains(where: { $0.bundleID == id && $0.profile == nil }) else { return }
                        session.checkpoint()
                        update { $0.rules.append(Rule(bundleID: id)) }
                    }
                    HelpText(slot.rules.isEmpty
                             ? "No app yet: this slot holds the windows you send to the drawer (\(session.shortcutLabel(edge == .left ? "drawerSendLeft" : "drawerSendRight")))."
                             : "Their windows go to this slot by themselves, on every desktop of this display. Other windows can still be sent here (\(session.shortcutLabel(edge == .left ? "drawerSendLeft" : "drawerSendRight"))).")
                }
                SwiftUI.Divider()
                Text(sizeWords(width: slot.rect.w, height: slot.rect.h))
                    .font(.callout).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ offset: Int, _ rule: Rule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let icon = AppIcons.small(rule.bundleID) { Image(nsImage: icon) }
                Text(appName(rule.bundleID)).lineLimit(1)
                Spacer()
                Button {
                    session.checkpoint()
                    update { if $0.rules.indices.contains(offset) { $0.rules.remove(at: offset) } }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Take \(appName(rule.bundleID)) out of this slot")
            }
            if isTabbedBrowser(rule.bundleID) {
                // The profiles Fremspace has seen in this browser's window titles.
                let known = session.engine.knownProfiles(bundleID: rule.bundleID)
                Picker("Browser profile", selection: Binding(
                    get: { rule.profile ?? "" },
                    set: { name in update { if $0.rules.indices.contains(offset) { $0.rules[offset].profile = name.isEmpty ? nil : name } } })) {
                    Text("Any profile").tag("")
                    ForEach(known, id: \.self) { Text($0).tag($0) }
                    if let current = rule.profile, !known.contains(current) { Text(current).tag(current) }
                }
                .labelsHidden().controlSize(.small)
            }
        }
    }
}

struct DesktopInspector: View {
    @ObservedObject var session: EditSession

    var body: some View {
        if let space = session.spaceSpec {
            InspectorSection("Desktop") {
                Field("Name") {
                    TextField("Name", text: Binding(get: { space.label }, set: { text in session.updateSpace { $0.label = text } }))
                        .textFieldStyle(.roundedBorder)
                }
                // Free or Layout is chosen above the screen (`DesktopMode`).
                SwiftUI.Divider()
                Button(role: .destructive) { session.removeDesktop(at: session.selection.desktop) } label: {
                    Label("Remove this desktop", systemImage: "trash")
                }
                .disabled((session.displaySpec?.spaces.count ?? 0) <= 1)
                .help("Takes the desktop out of the configuration; the macOS desktop itself stays")
            }
        }
    }
}

/// The drawer being edited: its width, how to use it, and its removal.
struct DrawerInspector: View {
    @ObservedObject var session: EditSession
    let edge: DrawerEdge

    var body: some View {
        if let drawer = session.displaySpec?.drawers.first(where: { $0.edge == edge }) {
            let width = session.geometry(of: session.selection.display).visible.width
            InspectorSection(edge == .left ? "Left drawer" : "Right drawer") {
                HelpText("A panel of windows that slides over the \(edge.rawValue) edge of this display, the same on each of its desktops.")
                Field("Width") {
                    Picker("Width", selection: Binding(
                        get: { drawer.size },
                        set: { size in session.updateDisplay { d in
                            if let i = d.drawers.firstIndex(where: { $0.edge == edge }) { d.drawers[i].size = size }
                        } })) {
                        let stops = Fractions.stops(forWidth: width).filter { $0 <= 0.5 }
                        ForEach(stops, id: \.self) { stop in Text(fractionLabel(stop)).tag(stop) }
                        // A width written by hand in the file stays selectable.
                        if !stops.contains(where: { abs($0 - drawer.size) < 0.001 }) { Text(fractionLabel(drawer.size)).tag(drawer.size) }
                    }
                    .labelsHidden().fixedSize()
                }
                Field("Shortcuts") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(session.shortcutLabel(edge == .left ? "drawerLeft" : "drawerRight"))  opens and closes it")
                        Text("\(session.shortcutLabel(edge == .left ? "drawerSendLeft" : "drawerSendRight"))  sends the front window to it, or takes it out")
                    }
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                SwiftUI.Divider()
                Button(role: .destructive) { session.removeDrawer(edge) } label: {
                    Label("Remove this drawer", systemImage: "trash")
                }
                .help("Windows in it come back on screen (Undo brings the drawer back)")
            }
        }
    }
}

struct DisplayInspector: View {
    @ObservedObject var session: EditSession

    var body: some View {
        InspectorSection("Display") {
            if let display = session.displaySpec {
                let geometry = session.geometry(of: display.identity)
                Field("Name") {
                    TextField(display.identity.name, text: Binding(get: { display.label },
                                                                   set: { name in session.renameDisplay(display.identity, to: name) }))
                        .textFieldStyle(.roundedBorder)
                    HelpText("What Fremspace calls this display, in every configuration. Empty: the name macOS gives it.")
                }
                HStack {
                    Text(display.identity.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(geometry.connected ? "\(Int(geometry.frame.width)) × \(Int(geometry.frame.height)) pt" : "Not connected")
                        .foregroundColor(.secondary).monospacedDigit()
                }
                .font(.callout)
            }
            SwitchRow(title: "Ignore this display", detail: "Fremspace never touches the windows on it.",
                      isOn: Binding(
                        get: { session.displaySpec?.ignored ?? false },
                        set: { on in
                            session.checkpoint()
                            session.updateDisplay { $0.ignored = on }
                            session.selection.slot = nil
                            session.selection.drawer = nil
                        }))
        }
    }
}
