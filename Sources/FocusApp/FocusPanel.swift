import AppKit
import SwiftUI

/// Always-on-top, draggable, resizable panel that does not steal focus from other apps.
final class FocusPanel: NSPanel {
    private static let autosaveName = "FocusPanel"
    /// Height the user had before "+N more" grew the panel; restored on fade.
    private var heightBeforeExpand: CGFloat?
    /// Height "+N more" grew the panel to. If the panel is a different height by the time
    /// we'd collapse, the user resized it by hand, and that size wins.
    private var expandedHeight: CGFloat?
    private var observers: [NSObjectProtocol] = []

    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 250),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        minSize = NSSize(width: 240, height: 120)
        contentView = NSHostingView(rootView: content)

        // Restore the remembered frame, or default to the top-right corner.
        if !setFrameUsingName(Self.autosaveName) { placeTopRight() }
        setFrameAutosaveName(Self.autosaveName)

        // No live-resize observer: animated setFrame also posts didEndLiveResize, which
        // used to wipe the "+N more" state right after growing. A manual resize is detected
        // instead by the height no longer matching expandedHeight (takeCollapseHeight).
    }

    /// Hiding (⌃⌥F, middle-click, the menu, or hide-while-replying) also undoes a
    /// "+N more" expansion, so the panel comes back at its regular size.
    override func orderOut(_ sender: Any?) {
        collapseNow()
        super.orderOut(sender)
    }

    /// Undo a "+N more" expansion immediately, without animating. Also called on quit:
    /// the frame is autosaved, so quitting while expanded would otherwise make the
    /// expanded height the new normal size at the next launch.
    func collapseNow() {
        guard let h = takeCollapseHeight() else { return }
        var f = frame
        f.origin.y = f.maxY - h
        f.size.height = h
        setFrame(f, display: false, animate: false)
    }

    // Needed so the inline "add task" field can take keyboard input.
    override var canBecomeKey: Bool { true }

    /// Grow downward by `delta` points, keeping the top edge in place, capped at the screen bottom.
    func grow(by delta: CGFloat) {
        guard delta > 0, let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        if heightBeforeExpand == nil { heightBeforeExpand = frame.height }
        let maxHeight = frame.maxY - visible.minY
        let target = min(frame.height + ceil(delta), maxHeight)
        expandedHeight = target
        setHeight(target)
    }

    /// The height to go back to, or nil if there's nothing to undo (never expanded, or
    /// resized by hand since). Clears the expansion either way.
    private func takeCollapseHeight() -> CGFloat? {
        defer { heightBeforeExpand = nil; expandedHeight = nil }
        guard let h = heightBeforeExpand, let e = expandedHeight, abs(frame.height - e) < 2 else { return nil }
        return h
    }

    /// Undo a "+N more" expansion, if one happened since the last manual resize.
    func restoreHeight() {
        guard let h = takeCollapseHeight() else { return }
        setHeight(h)
    }

    private func setHeight(_ height: CGFloat) {
        var f = frame
        f.origin.y = f.maxY - height
        f.size.height = height
        setFrame(f, display: true, animate: true)
    }

    func placeTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 16, y: screen.maxY - frame.height - 16))
    }
}
