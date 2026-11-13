import AppKit
import SwiftUI

/// A short-lived mark at the bottom of a slot while the owner goes through its windows: the app and
/// title of the window now shown, and one dot per window of the slot, the shown one filled. It takes
/// no click and no keyboard, and goes by itself.
final class StackHUD {
    /// How long the mark stays after the last step.
    static let stay: TimeInterval = 1.1

    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    /// `frame`: the slot, in AX coordinates.
    func show(count: Int, index: Int, title: String, icon: NSImage?, over frame: CGRect) {
        guard count > 1, let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = NSHostingView(rootView: StackMark(count: count, index: index, title: title, icon: icon,
                                                     maxWidth: max(160, frame.width - 48)))
        let size = view.fittingSize
        panel.contentView = view
        // Centred, a little above the bottom of the slot (AppKit coordinates: y goes up).
        let origin = NSPoint(x: frame.midX - size.width / 2,
                             y: primary.frame.height - frame.maxY + 28)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self?.panel?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // A new step may have shown it again meanwhile.
                if self?.panel?.alphaValue == 0 { self?.panel?.orderOut(nil) }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

private struct StackMark: View {
    let count: Int
    let index: Int
    let title: String
    let icon: NSImage?
    let maxWidth: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(title.isEmpty ? "Untitled" : title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    Circle().fill(Color.primary.opacity(i == index ? 0.9 : 0.25)).frame(width: 7, height: 7)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: maxWidth)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Window \(index + 1) of \(count): \(title)")
    }
}
