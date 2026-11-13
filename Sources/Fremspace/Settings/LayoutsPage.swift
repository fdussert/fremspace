import AppKit
import FremspaceCore
import SwiftUI
import UniformTypeIdentifiers

/// The Layouts page: layouts chosen from pictures. For one desktop, the ready-made ones and the
/// desktops kept, with a preview of what the one chosen makes of the desktop the editor shows; for
/// a whole desk, the layout files, each seen in full before anything of it is added. A layout file
/// used to be understood by opening its JSON, and a new owner started from an empty desktop.
struct LayoutsPage: View {
    @ObservedObject var session: EditSession
    /// Whether a ready-made layout gives Focus to its largest slot. An option of the next "Use",
    /// the owner's taste, kept outside the config file like the sections left open or folded.
    @AppStorage("layouts.focusOnLargest") private var focusOnLargest = true
    @State private var dropTargeted = false
    /// The card that has the keyboard, which the arrow keys move.
    @SwiftUI.FocusState private var focusedCard: String?
    /// How many cards a row holds, for the arrow keys that go up and down.
    @State private var columns = 4

    private static let grid = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if session.configuration == nil {
                NoConfiguration(session: session, text: "A layout goes on a desktop of a configuration: make one first.")
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if session.layoutsView == .oneDesktop {
                oneDesktop
            } else if let pending = session.pendingImport {
                ImportDetail(session: session, pending: pending)
            } else {
                wholeDesks
            }
        }
        .onAppear { arrive() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in drop(providers) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).padding(6).allowsHitTesting(false)
            }
        }
    }

    /// The page opens on something to look at: a layout chosen, on a display that can take one.
    private func arrive() {
        session.refreshLibrary()
        if session.displaySpec?.ignored == true, let usable = session.configuration?.displays.first(where: { !$0.ignored }) {
            session.select(display: usable.identity)
        }
        if session.layoutChoice.flatMap(session.layoutName) == nil, let first = layoutPresets.first {
            session.layoutChoice = .preset(first.id)
        }
    }

    /// A layout file dropped anywhere on the page is opened as "Import a file…" opens one.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { session.openLayoutFile(url) }
        }
        return true
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                PageTitle(session: session, page: .layouts)
                Text(SettingsPage.layouts.summary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("What the layouts are for", selection: $session.layoutsView) {
                Text("For one desktop").tag(LayoutsView.oneDesktop)
                Text("Whole desks").tag(LayoutsView.wholeDesks)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button("Import a file\u{2026}") { session.chooseImport() }
                .help("Open a .fremspace-layout.json somebody sent you; you see what it holds before anything is added")
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
    }

    private func sectionTitle(_ title: String, _ about: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(about).font(.subheadline).foregroundColor(.secondary)
        }
    }

    // MARK: - For one desktop

    private var oneDesktop: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    readyMade
                    yours
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { measure(proxy.size.width) }.onChange(of: proxy.size.width) { measure($0) }
                })
                // The arrow keys go from card to card, as in any grid.
                .onMoveCommand { move($0) }
            }
            Divider()
            // Wider than the editor's inspector: a third of a display must still be a tile wide
            // enough for its app's name and its size.
            LayoutPreview(session: session, focusOnLargest: focusOnLargest)
                .frame(width: 330)
        }
    }

    private func measure(_ width: CGFloat) {
        columns = max(1, Int((width - 48 + 12) / (150 + 12)))
    }

    /// The cards in the order they are read, ready-made first.
    private var cards: [LayoutChoice] {
        layoutPresets.map { .preset($0.id) } + session.keptDesktops.map { .kept($0.id) }
    }

    private func cardID(_ choice: LayoutChoice) -> String {
        switch choice {
        case .preset(let id): return "preset.\(id)"
        case .kept(let file): return "kept.\(file)"
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        let all = cards
        guard let current = session.layoutChoice.flatMap({ all.firstIndex(of: $0) }) else { return }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columns
        case .down: step = columns
        @unknown default: return
        }
        let next = current + step
        guard all.indices.contains(next) else { return }
        session.layoutChoice = all[next]
        focusedCard = cardID(all[next])
    }

    private var readyMade: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                sectionTitle("Ready made", "Empty slots: you choose the apps.")
                Spacer(minLength: 8)
                Toggle("Focus on the largest slot", isOn: $focusOnLargest).toggleStyle(.switch).controlSize(.small)
                    .help("A ready-made layout gives Focus to its largest slot; the drawings show which")
            }
            LazyVGrid(columns: Self.grid, alignment: .leading, spacing: 12) {
                ForEach(layoutPresets) { preset in
                    let choice = LayoutChoice.preset(preset.id)
                    let spoken = "\(preset.name): \(preset.detail)" + (focusOnLargest ? ", Focus on the largest" : "")
                    LayoutCard(name: preset.name, detail: preset.detail, selected: session.layoutChoice == choice, spoken: spoken,
                               drawing: LayoutMiniature(desktop: reshaped(SpaceSpec(label: preset.name), to: preset.rects, focusOnLargest: focusOnLargest).desktop,
                                                        content: .shapes, spoken: spoken)) {
                        session.layoutChoice = choice
                    }
                    .focused($focusedCard, equals: cardID(choice))
                }
            }
        }
    }

    private var yours: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Yours", "Kept from your desktops, or from a file. Their apps come with them.")
            LazyVGrid(columns: Self.grid, alignment: .leading, spacing: 12) {
                ForEach(session.keptDesktops) { item in kept(item) }
                keepCard
            }
        }
    }

    @ViewBuilder
    private func kept(_ item: EditSession.LibraryItem) -> some View {
        if let desktop = item.layout.singleDesktop {
            let choice = LayoutChoice.kept(item.id)
            let away = Set(desktop.layout?.slots.flatMap(\.rules).map(\.bundleID).filter { !$0.isEmpty && AppIcons.icon($0) == nil } ?? [])
            let spoken = "\(item.layout.name): \(layoutInWords(desktop, appName: appName, missing: away))"
            LayoutCard(name: item.layout.name, detail: layoutCounts(desktop), selected: session.layoutChoice == choice, spoken: spoken,
                       drawing: LayoutMiniature(desktop: desktop, content: .icons, aspect: CGFloat(item.layout.displays.first?.aspect ?? 1.6),
                                                missing: away, spoken: spoken)) {
                session.layoutChoice = choice
            }
            .focused($focusedCard, equals: cardID(choice))
            .contextMenu {
                Button("Show in the Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                SwiftUI.Divider()
                Button("Remove from Layouts") { session.removeFromLibrary(item) }
            }
        }
    }

    /// Keeps the desktop the editor shows; also where the page says a file can be dropped.
    private var keepCard: some View {
        let free = session.spaceSpec?.layout == nil
        let name = session.spaceSpec.map { $0.label.isEmpty ? "the desktop shown" : "\u{201C}\($0.label)\u{201D}" } ?? "the desktop shown"
        return Button { session.keepShownDesktop() } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                Text("Keep the desktop shown").multilineTextAlignment(.center)
                Text("or drop a layout file here").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 160)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(free)
        .help(free ? "The desktop the editor shows is free: it has no layout to keep"
              : "Keeps \(name) of \(session.displaySpec?.displayName ?? "its display"), as the editor shows it. Its drawers are the display's and stay with it.")
    }

    // MARK: - Whole desks

    private var wholeDesks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Whole desks", "Several desktops, with their displays, drawers and scenes. Choose one to see it before anything is added.")
                LazyVGrid(columns: Self.grid, alignment: .leading, spacing: 12) {
                    ForEach(session.wholeDesks) { item in
                        let spoken = "\(item.layout.name): \(deskCounts(item.layout))"
                        LayoutCard(name: item.layout.name, detail: deskCounts(item.layout), selected: false, spoken: spoken,
                                   drawing: DeskMiniature(layout: item.layout, spoken: spoken)) {
                            session.readImport(item.url)
                        }
                        .contextMenu {
                            Button("Show in the Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            SwiftUI.Divider()
                            Button("Remove from Layouts") { session.removeFromLibrary(item) }
                        }
                    }
                    importCard
                }
                HStack(spacing: 10) {
                    Button("Open the Layouts folder") { session.openLibraryFolder() }
                        .help("The folder beside the config file where the layouts kept are; a layout file put there is listed here")
                    Text("The Share page keeps a configuration here.").font(.subheadline).foregroundColor(.secondary)
                }
                .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importCard: some View {
        Button { session.chooseImport() } label: {
            VStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 18, weight: .medium))
                Text("Import a file\u{2026}").multilineTextAlignment(.center)
                Text("or drop a layout file here").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 160)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A layout to choose: its drawing, its name, and under it what the drawing cannot say at its size.
/// One element for VoiceOver, which reads what the drawing shows.
struct LayoutCard<Drawing: View>: View {
    let name: String
    let detail: String
    let selected: Bool
    let spoken: String
    let drawing: Drawing
    let choose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                drawing.frame(maxWidth: .infinity).frame(height: 92)
                Text(name).fontWeight(.semibold).lineLimit(1)
                Text(detail).font(.subheadline).foregroundColor(.secondary).lineLimit(2, reservesSpace: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose() }
    }
}

/// Beside the grid: the layout chosen as it would be on the desktop the editor shows, drawn at the
/// shape of its display; which desktop that is; what would change there, in words; and the two
/// ways to use it. Both are edits like any other: one step to undo, nothing moves until Save.
struct LayoutPreview: View {
    @ObservedObject var session: EditSession
    let focusOnLargest: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let target = session.layoutTarget, let choice = session.layoutChoice,
                   let outcome = session.layoutOutcome(choice, on: target.desktop, focusOnLargest: focusOnLargest) {
                    chosen(choice, outcome, display: target.display, index: target.index, desktop: target.desktop)
                } else if session.layoutTarget == nil {
                    HelpText("The display the editor shows is ignored, or has no desktop: a layout has nowhere to go.")
                    whereTo
                } else {
                    HelpText("Choose a layout to see what it makes of this desktop.")
                    whereTo
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func chosen(_ choice: LayoutChoice, _ outcome: LayoutOutcome, display: DisplaySpec, index: Int, desktop: SpaceSpec) -> some View {
        let geometry = session.geometry(of: display.identity)
        let label = desktop.label.isEmpty ? "desktop \(index + 1)" : "\u{201C}\(desktop.label)\u{201D}"
        VStack(alignment: .leading, spacing: 2) {
            Text(outcome.name).font(.headline).lineLimit(1)
            HelpText(geometry.connected
                     ? "As it would be on \(display.displayName), \(Int(geometry.visible.width)) × \(Int(geometry.visible.height)) pt"
                     : "As it would be on \(display.displayName), which is not connected: drawn as 16:10")
        }
        DesktopDrawing(desktop: outcome.desktop, aspect: geometry.visible.width / max(geometry.visible.height, 1),
                       spoken: "\(outcome.name) on \(label): \(layoutInWords(outcome.desktop, appName: appName))")
            .frame(maxWidth: .infinity, maxHeight: 240)
        whereTo
        InspectorCard {
            Text("What changes on \(label)").fontWeight(.semibold)
            ForEach(sentences(outcome, over: desktop, drawers: display.drawers.count), id: \.self) { sentence in
                Text(sentence).font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // The editor's tile cannot say it: an app without an icon looks like any other.
            let away = notOnThisMac(outcome.desktop)
            if !away.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: Status.Kind.warning.symbol).foregroundColor(.orange)
                    Text("\(listed(away)) \(away.count == 1 ? "is" : "are") not on this Mac: \(away.count == 1 ? "its slot stays" : "their slots stay") empty until \(away.count == 1 ? "it is" : "they are") installed.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
            }
        }
        let same = outcome.desktop == desktop
        VStack(spacing: 8) {
            Button { session.useLayout(choice, focusOnLargest: focusOnLargest) } label: {
                Text("Use on this desktop").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .disabled(same)
            .help(same ? "This desktop already is as the drawing shows" : "Changes \(label) as the drawing shows; Undo takes it back")
            Button { session.addLayoutAsDesktop(choice, focusOnLargest: focusOnLargest) } label: {
                Text("Add as a new desktop").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("Leaves \(label) as it is and adds a desktop after the \(display.spaces.count) of \(display.displayName)")
            Text("Nothing moves until you Save.").font(.subheadline).foregroundColor(.secondary)
        }
        if case .kept(let file) = choice, let item = session.library.first(where: { $0.id == file }) {
            Button(role: .destructive) { session.removeFromLibrary(item) } label: {
                Label("Remove from Layouts", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .help("Moves its file to the Trash, where it can be taken back")
        }
    }

    /// The apps of a desktop that are not installed here, by the name they are shown under.
    private func notOnThisMac(_ desktop: SpaceSpec) -> [String] {
        var names: [String] = []
        for id in (desktop.layout?.slots ?? []).flatMap(\.rules).map(\.bundleID) where !id.isEmpty && AppIcons.icon(id) == nil {
            if !names.contains(appName(id)) { names.append(appName(id)) }
        }
        return names
    }

    /// What using the layout changes, from the rule that makes the change (`reshapeInWords`,
    /// `replacementInWords`): a ready-made layout keeps the apps, a kept one comes with its own.
    private func sentences(_ outcome: LayoutOutcome, over desktop: SpaceSpec, drawers: Int) -> [String] {
        if let reshaped = outcome.reshaped {
            return reshapeInWords(reshaped, from: desktop, focusOnLargest: focusOnLargest, drawers: drawers, appName: appName)
        }
        return replacementInWords(outcome.alone, over: desktop, drawers: drawers, appName: appName)
    }

    /// The display and the desktop: the ones the editor shows, changed here as there.
    @ViewBuilder
    private var whereTo: some View {
        let displays = session.configuration?.displays.filter { !$0.ignored } ?? []
        if !displays.isEmpty {
            Field("Where") {
                HStack(spacing: 8) {
                    Choice(options: displays.enumerated().map { ($0.element.displayName, $0.offset) },
                           selection: displays.firstIndex { $0.identity == session.selection.display } ?? 0,
                           name: "The display the layout goes on", width: 145) { choice in
                        if displays.indices.contains(choice) { session.select(display: displays[choice].identity) }
                    }
                    let desktops = session.displaySpec?.spaces ?? []
                    Choice(options: desktops.enumerated().map { ("\($0.offset + 1). \($0.element.label)", $0.offset) },
                           selection: session.selection.desktop, name: "The desktop the layout goes on", width: 145) { choice in
                        session.select(desktop: choice)
                    }
                }
            }
        }
    }
}

/// A whole desk seen before it is added: one row for each display of the file, with its desktops
/// drawn and the apps named in their slots, and which display here takes it; beside, what comes
/// with it and what does not. Nothing of a file is taken at its word, and nothing is added unseen.
struct ImportDetail: View {
    @ObservedObject var session: EditSession
    let pending: EditSession.PendingImport

    private static let grid = [GridItem(.adaptive(minimum: 130, maximum: 210), spacing: 10, alignment: .top)]

    var body: some View {
        let displays = session.configuration?.displays.filter { !$0.ignored } ?? []
        let missing = Set(session.importMissingApps)
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    top
                    HelpText("Each row is one of its displays. Choose which of yours takes it; the drawings follow the shape of your display.")
                    ForEach(Array(pending.layout.displays.enumerated()), id: \.offset) { position, display in
                        row(position, display, onto: displays, missing: missing)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ScrollView { aside(displays: displays, missing: missing) }
                .frame(width: 330)
        }
    }

    private var top: some View {
        HStack(spacing: 10) {
            Button { session.pendingImport = nil } label: { Label("Whole desks", systemImage: "chevron.left") }
                .keyboardShortcut(.cancelAction)
                .help("Back to the layouts, without adding this one (Esc)")
            Text(pending.layout.name).font(.title3.weight(.semibold)).lineLimit(1)
            Text(pending.kept ? "Kept in Layouts" : "A file, not in your desk yet")
                .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(pending.kept ? Color.primary.opacity(0.09) : Color.orange.opacity(0.22)))
            Spacer(minLength: 8)
            Text(pending.file).font(.subheadline).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func row(_ position: Int, _ display: SharedDisplay, onto displays: [DisplaySpec], missing: Set<String>) -> some View {
        let target = pending.mapping[position].flatMap { identity in displays.first { $0.identity == identity } }
        let here = target.map { session.geometry(of: $0.identity).visible }.map { Double($0.width / max($0.height, 1)) }
        // On the display that takes them; left out, at the shape they were made for.
        let aspect = CGFloat(here ?? display.aspect ?? 1.6)
        let warning = here.flatMap { shapeFitInWords(shapeFit(madeFor: display.aspect, here: $0)) }
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Their \u{201C}\(display.name)\u{201D}").fontWeight(.semibold).lineLimit(2)
                Text("goes on your").font(.subheadline).foregroundColor(.secondary)
                Choice(options: [("Leave it out", -1)] + displays.enumerated().map { ($0.element.displayName, $0.offset) },
                       selection: target.flatMap { own in displays.firstIndex { $0.identity == own.identity } } ?? -1,
                       name: "Which display takes the desktops of \(display.name)", width: 160) { choice in
                    session.mapImport(position, to: displays.indices.contains(choice) ? displays[choice].identity : nil)
                }
                if let target {
                    Text("\(counted(display.desktops.count, "desktop")), after your \(target.spaces.count)")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                ForEach(display.drawers, id: \.edge) { drawer in
                    Text(target?.drawers.contains { $0.edge == drawer.edge } == true
                         ? "Its \(drawer.edge.rawValue) drawer is left out: yours stays"
                         : "With a \(drawer.edge.rawValue) drawer")
                        .font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let warning {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: Status.Kind.warning.symbol).foregroundColor(.orange)
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                }
            }
            .frame(width: 170, alignment: .leading)
            LazyVGrid(columns: Self.grid, alignment: .leading, spacing: 10) {
                ForEach(Array(display.desktops.enumerated()), id: \.offset) { _, desktop in
                    VStack(alignment: .leading, spacing: 5) {
                        LayoutMiniature(desktop: desktop, content: .names, aspect: aspect, drawers: display.drawers.map(\.edge), missing: missing,
                                        spoken: "\(desktop.label): \(layoutInWords(desktop, appName: appName, missing: missing))")
                            .frame(maxWidth: .infinity).frame(height: 96)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(desktop.label).fontWeight(.semibold).lineLimit(1)
                            Text(desktop.layout.map { counted($0.slots.count, "slot") } ?? "free")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                }
            }
            // What is left out is still shown, behind: the owner may change their mind.
            .opacity(target == nil ? 0.5 : 1)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private func aside(displays: [DisplaySpec], missing: Set<String>) -> some View {
        let layout = pending.layout
        let report = session.importReport ?? ImportReport()
        let names = Dictionary(uniqueKeysWithValues: pending.mapping.compactMap { position, identity in
            displays.first { $0.identity == identity }.map { (position, $0.displayName) }
        })
        let configuration = session.configuration?.name ?? ""
        // Said of what comes only: a display left out brings no app to miss, and opens none.
        let taken = Set(names.keys)
        let missing = missing.intersection(layout.apps(taking: taken))
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What comes with it").font(.headline)
                HelpText(importInWords(report, of: layout))
            }
            if !layout.scenes.isEmpty {
                InspectorCard {
                    Text("Scenes").fontWeight(.semibold)
                    ForEach(Array(layout.scenes.enumerated()), id: \.offset) { _, scene in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(scene.name)
                            Text(sceneInWords(scene, of: layout, displayNames: names, appName: appName))
                                .font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !missing.isEmpty {
                let several = missing.count > 1
                note("\(counted(missing.count, "app")) \(several ? "are" : "is") not on this Mac",
                     "\(listed(missing.sorted().map(appName))). \(several ? "Their slots are" : "Its slot is") added and \(several ? "stay" : "stays") empty until \(several ? "they are" : "it is") installed, or until you choose another app.",
                     warning: true)
            }
            let atLogin = layout.appsOpenedAtLogin(taking: taken).filter { !missing.contains($0) }
            if !atLogin.isEmpty {
                note("Opened at your next login", "\(listed(atLogin.map(appName))), unless you switch that off in their slots.")
            }
            note("Not in the file", "The models and serial numbers of their displays, their shortcuts and their settings."
                 + (session.importHasFilters ? " It does name browser profiles or window title filters: they are the author's, change them to yours in the slots." : ""))
            if report.drawersKept > 0 {
                HelpText("\(counted(report.drawersKept, "drawer")) of the file \(report.drawersKept == 1 ? "is" : "are") on an edge that has yours: yours \(report.drawersKept == 1 ? "stays" : "stay").")
            }
            HelpText("macOS needs as many desktops as the configuration lists: after you save, the Status page offers to add the ones that are missing.")
            VStack(spacing: 8) {
                Button { session.applyImport() } label: {
                    Text("Add to \u{201C}\(configuration)\u{201D}").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(report.desktops == 0)
                .help(report.desktops == 0 ? "Choose which of your displays takes at least one of its rows" : "Adds its desktops after yours; Undo takes them back")
                if pending.kept {
                    Button(role: .destructive) {
                        if let item = session.library.first(where: { $0.id == pending.file }) { session.removeFromLibrary(item) }
                    } label: {
                        Text("Remove from Layouts").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help("Moves its file to the Trash, where it can be taken back")
                } else {
                    Button { session.keepPendingImport() } label: {
                        Text("Only keep it in Layouts").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help("Keeps a copy among the whole desks, and adds nothing to the configuration")
                }
                Text("Your own desktops stay. Nothing moves until you Save.").font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A card of the aside: what it is about, and one sentence. A warning is tinted as the Status
    /// page tints what needs the owner.
    private func note(_ title: String, _ text: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            Text(text).font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(warning ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05)))
    }
}
