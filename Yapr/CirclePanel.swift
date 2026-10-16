import AppKit
import SwiftUI

/// A borderless, transparent, non-activating panel that holds the circle.
final class CirclePanel: NSPanel {
    init() {
        let size = CircleView.windowSize
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false            // DragHandleView moves it
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the circle under the menu bar icon, hides it on an outside click, and lets it be dragged away to float on its own.
/// Dropping it back near the icon re-attaches it.
final class CirclePanelController {
    private let panel = CirclePanel()
    private var outsideClickMonitor: Any?
    private(set) var isDetached = false
    private var hideGeneration = 0
    private let statusButtonFrame: () -> NSRect?

    private static let snapDistance: CGFloat = 44

    init(model: AppModel, statusButtonFrame: @escaping () -> NSRect?) {
        self.statusButtonFrame = statusButtonFrame
        let root = CircleView(model: model,
                              onDragBegan: { [weak self] in self?.dragBegan() },
                              onDragEnded: { [weak self] in self?.dragEnded() })
        panel.contentView = FirstMouseHostingView(rootView: root)
    }

    var isVisible: Bool { panel.isVisible }
    var contentView: NSView? { panel.contentView }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        hideGeneration += 1
        if !isDetached, let origin = attachedOrigin() { panel.setFrameOrigin(origin) }
        panel.level = isDetached ? .floating : .statusBar
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        startOutsideClickMonitor()
    }

    func hide() {
        stopOutsideClickMonitor()
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == generation else { return }   // shown again meanwhile
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    /// Top of the circle just under the menu bar, centred on the icon, kept on screen.
    private func attachedOrigin() -> NSPoint? {
        guard let button = statusButtonFrame() else { return nil }
        let size = CircleView.windowSize, m = CircleView.margin
        var x = button.midX - size / 2
        let y = button.minY - 6 - size + m
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: button.midX, y: button.midY)) }) {
            x = min(max(x, screen.visibleFrame.minX - m + 8), screen.visibleFrame.maxX - size + m - 8)
        }
        return NSPoint(x: x, y: y)
    }

    private func dragBegan() {
        isDetached = true
        panel.level = .floating
    }

    private func dragEnded() {
        guard let home = attachedOrigin() else { return }
        let o = panel.frame.origin
        if hypot(o.x - home.x, o.y - home.y) < CirclePanelController.snapDistance {
            isDetached = false
            panel.level = .statusBar
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(home)
            }
        }
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isDetached else { return }
            self.hide()
        }
    }

    private func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }
}
