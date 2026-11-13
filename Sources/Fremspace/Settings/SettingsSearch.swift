import AppKit
import FremspaceCore
import SwiftUI

/// The sections of the settings pages.
enum SettingSection: String {
    case generalFremspace = "general.fremspace"
    case generalFloating = "general.floating"
    case generalSlots = "general.slots"
    case generalDesktops = "general.desktops"
    case generalCalls = "general.calls"
    case shortcutsHyper = "shortcuts.hyper"
    case maintenanceLayouts = "maintenance.layouts"
    case maintenanceWindows = "maintenance.windows"
    case maintenanceFile = "maintenance.file"
    case maintenanceDiagnostics = "maintenance.diagnostics"

    var title: String {
        switch self {
        case .generalFremspace: return "Running"
        case .generalFloating: return "Windows without a slot"
        case .generalSlots: return "Slots"
        case .generalDesktops: return "Desktops"
        case .generalCalls: return "Calls in full screen"
        case .shortcutsHyper: return "Hyper key"
        case .maintenanceLayouts: return "Layouts"
        case .maintenanceWindows: return "Windows"
        case .maintenanceFile: return "Config file"
        case .maintenanceDiagnostics: return "Diagnostics"
        }
    }
}

/// The switches and commands of the settings pages. The pages take their names here and the search
/// lists them, so a setting cannot be on a page without being found.
enum SettingRow: String, CaseIterable {
    case openAtLogin, paused, autoUpdates, checkForUpdates, noFloating, resizeLayouts, desktopNames, notchMap, windowPreviews, fullScreenCalls, hyperKey
    case reapply, restoreEverything, bringBack, openConfigFile, reloadConfig, copyDiagnostics, dumpWindows

    var title: String {
        switch self {
        case .openAtLogin: return "Open at login"
        case .paused: return "Pause Fremspace"
        case .autoUpdates: return "Look for a newer version every day"
        case .checkForUpdates: return "Check for updates"
        case .noFloating: return "No floating windows on layout desktops"
        case .resizeLayouts: return "Resize neighbouring slots together"
        case .desktopNames: return "Show the desktop's name when switching"
        case .notchMap: return "Map of desktops at the notch"
        case .windowPreviews: return "Window previews"
        case .fullScreenCalls: return "Calls in full screen"
        case .hyperKey: return "Use Caps Lock as ⌃⌥⌘"
        case .reapply: return "Re-apply the layouts"
        case .restoreEverything: return "Restore everything now"
        case .bringBack: return "Bring every window back on screen"
        case .openConfigFile: return "Open the config file"
        case .reloadConfig: return "Reload the config file"
        case .copyDiagnostics: return "Copy diagnostics"
        case .dumpWindows: return "Dump windows"
        }
    }

    var page: SettingsPage {
        switch self {
        case .openAtLogin, .paused, .autoUpdates, .checkForUpdates, .noFloating, .resizeLayouts, .desktopNames, .notchMap, .windowPreviews,
             .fullScreenCalls: return .general
        case .hyperKey: return .shortcuts
        default: return .maintenance
        }
    }

    var section: SettingSection {
        switch self {
        case .openAtLogin, .paused, .autoUpdates, .checkForUpdates: return .generalFremspace
        case .noFloating: return .generalFloating
        case .resizeLayouts: return .generalSlots
        case .desktopNames, .notchMap, .windowPreviews: return .generalDesktops
        case .fullScreenCalls: return .generalCalls
        case .hyperKey: return .shortcutsHyper
        case .reapply, .restoreEverything: return .maintenanceLayouts
        case .bringBack: return .maintenanceWindows
        case .openConfigFile, .reloadConfig: return .maintenanceFile
        case .copyDiagnostics, .dumpWindows: return .maintenanceDiagnostics
        }
    }

    /// Other words the owner may type for it.
    var keywords: [String] {
        switch self {
        case .openAtLogin: return ["start", "startup", "launch", "boot"]
        case .paused: return ["paused", "stop", "resume"]
        case .autoUpdates: return ["update", "upgrade", "version", "automatic", "mise à jour"]
        case .checkForUpdates: return ["update", "upgrade", "version", "new", "mise à jour"]
        case .noFloating: return ["free desktop", "unmatched", "float"]
        case .resizeLayouts: return ["dragging", "edge", "divider", "border", "swap"]
        case .desktopNames: return ["banner", "label", "notch", "space", "display changes"]
        case .notchMap: return ["hover", "pointer", "resting", "encoche", "switcher", "overview"]
        case .windowPreviews: return ["picture", "thumbnail", "screen recording", "palette", "aperçu", "vignette"]
        case .fullScreenCalls: return ["Teams", "Zoom", "meeting", "fullscreen"]
        case .hyperKey: return ["hyper", "caps lock", "verr maj"]
        case .reapply: return ["reapply", "fix", "sort"]
        case .restoreEverything: return ["login", "reopen"]
        case .bringBack: return ["lost", "drawer", "off screen", "recover"]
        case .openConfigFile: return ["json", "edit"]
        case .reloadConfig: return ["json", "read"]
        case .copyDiagnostics: return ["debug", "report", "clipboard"]
        case .dumpWindows: return ["debug", "list"]
        }
    }
}

/// Marks the row a search result pointed at, and lets the page scroll to it.
struct Revealable: ViewModifier {
    @ObservedObject var session: EditSession
    let row: SettingRow

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(session.revealed == row.rawValue ? 0.22 : 0)).padding(-6))
            .animation(.easeOut(duration: 0.3), value: session.revealed)
            .id(row.rawValue)
    }
}

/// One result of the sidebar's search and where it leads.
struct SearchHit: Identifiable {
    enum Target {
        case page(SettingsPage)
        case row(SettingRow)
        case shortcut(ShortcutCatalog.Entry)
        case configuration(Int)
        case desktop(Selection)
        case scenes(configuration: Int)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let target: Target
}

extension EditSession {
    /// Everything the window holds that has a name: pages, settings, commands, configurations,
    /// desktops, scenes and shortcuts.
    private var searchable: [(hit: SearchHit, keywords: [String])] {
        var all: [(SearchHit, [String])] = []
        for page in SettingsPage.allCases {
            all.append((SearchHit(id: "page.\(page.rawValue)", title: page.title, subtitle: "Page", symbol: page.symbol, target: .page(page)), []))
        }
        // A build without an updater has nothing to find about updates.
        let updateRows: Set<SettingRow> = engine.updates.isAvailable ? [] : [.autoUpdates, .checkForUpdates]
        for row in SettingRow.allCases where !updateRows.contains(row) {
            all.append((SearchHit(id: "row.\(row.rawValue)", title: row.title, subtitle: "\(row.page.title) \u{203A} \(row.section.title)",
                                  symbol: row.page.symbol, target: .row(row)), row.keywords))
        }
        for (c, configuration) in config.configurations.enumerated() {
            all.append((SearchHit(id: "configuration.\(configuration.id)", title: configuration.name, subtitle: "Configuration",
                                  symbol: "rectangle.3.group", target: .configuration(c)), []))
            for display in configuration.displays {
                for (d, space) in display.spaces.enumerated() {
                    let apps = space.layout?.slots.flatMap { $0.rules.map(\.bundleID) } ?? []
                    all.append((SearchHit(id: "desktop.\(configuration.id).\(display.identity.name).\(d)", title: space.label,
                                          subtitle: "Desktop \(d + 1) of \(display.displayName), \(configuration.name)", symbol: "macwindow",
                                          target: .desktop(Selection(configuration: c, display: display.identity, desktop: d))),
                                apps + apps.compactMap { $0.split(separator: ".").last.map(String.init) }))
                }
            }
            for scene in configuration.scenes {
                all.append((SearchHit(id: "scene.\(scene.id)", title: scene.name, subtitle: "Scene of \(configuration.name)",
                                      symbol: SettingsPage.scenes.symbol, target: .scenes(configuration: c)), []))
            }
        }
        let effective = ShortcutCatalog.effective(config.shortcuts)
        for entry in ShortcutCatalog.entries {
            let label = effective[entry.id].map(ShortcutCatalog.label) ?? "None"
            all.append((SearchHit(id: "shortcut.\(entry.id)", title: entry.title, subtitle: "Shortcut \u{203A} \(entry.group), \(label)",
                                  symbol: SettingsPage.shortcuts.symbol, target: .shortcut(entry)), [label]))
        }
        return all
    }

    /// What `search` finds, best first (the palette's matching: starts of words, initials, accents
    /// and case aside). Letters scattered in a word are not enough here: in a list this short they
    /// bring up settings that have nothing to do with what was typed.
    var searchHits: [SearchHit] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var scored: [(hit: SearchHit, score: Int, order: Int)] = []
        for (order, entry) in searchable.enumerated() {
            let item = PaletteItem(id: entry.hit.id, kind: .command, title: entry.hit.title, subtitle: entry.hit.subtitle, keywords: entry.keywords)
            guard let score = paletteScore(query, item: item), score >= 30 else { continue }
            scored.append((entry.hit, score, order))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(12).map(\.hit)
    }

    /// Goes where a result leads and ends the search.
    func open(_ hit: SearchHit) {
        search = ""
        switch hit.target {
        case .page(let page):
            settingsPage = page
        case .row(let row):
            shortcutFilter = ""
            settingsPage = row.page
            reveal(row.rawValue)
        case .shortcut(let entry):
            UserDefaults.standard.set(true, forKey: "fold.shortcuts.\(entry.group)")
            shortcutFilter = entry.title
            settingsPage = .shortcuts
        case .configuration(let index):
            settingsPage = nil
            select(configuration: index)
        case .desktop(let target):
            settingsPage = nil
            selection = target
            normalizeSelection()
        case .scenes(let index):
            select(configuration: index)
            settingsPage = .scenes
        }
    }
}

/// Lets ⌘F reach the search field.
final class SearchFocus {
    weak var field: NSSearchField?

    func take() {
        guard let field else { return }
        field.window?.makeFirstResponder(field)
    }
}

/// The sidebar's search field: ↑ ↓ move in the results, Return opens one, Escape ends the search.
struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focus: SearchFocus
    var onMove: (Int) -> Void
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.controlSize = .regular
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search settings, desktops and shortcuts")
        focus.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        focus.field = field
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SidebarSearchField

        init(_ parent: SidebarSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                guard !parent.text.isEmpty else { return false }
                parent.text = ""
            default: return false
            }
            return true
        }
    }
}

/// The results, in place of the sidebar's lists while something is typed.
struct SearchResults: View {
    @ObservedObject var session: EditSession
    let hits: [SearchHit]
    let selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hits.isEmpty {
                Text("Nothing is named \u{201C}\(session.search)\u{201D}.").font(.callout).foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                let chosen = index == selected
                Button {
                    session.open(hit)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: hit.symbol).frame(width: 18).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.title).lineLimit(2).multilineTextAlignment(.leading)
                            Text(hit.subtitle).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                .foregroundColor(chosen ? .white.opacity(0.75) : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .foregroundColor(chosen ? .white : .primary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
