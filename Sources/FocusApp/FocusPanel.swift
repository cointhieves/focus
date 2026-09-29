import AppKit
import SwiftUI

/// Always-on-top, draggable, resizable panel that does not steal focus from other apps.
final class FocusPanel: NSPanel {
    private static let autosaveName = "FocusPanel"
    /// Height the user had before "+N more" grew the panel; restored on fade.
    private var heightBeforeExpand: CGFloat?
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

        // A manual resize becomes the new baseline height for "+N more".
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                                                object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.heightBeforeExpand = nil }
        })
    }

    // Needed so the inline "add task" field can take keyboard input.
    override var canBecomeKey: Bool { true }

    /// Grow downward by `delta` points, keeping the top edge in place, capped at the screen bottom.
    func grow(by delta: CGFloat) {
        guard delta > 0, let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        if heightBeforeExpand == nil { heightBeforeExpand = frame.height }
        let maxHeight = frame.maxY - visible.minY
        setHeight(min(frame.height + ceil(delta), maxHeight))
    }

    /// Undo a "+N more" expansion, if one happened since the last manual resize.
    func restoreHeight() {
        guard let h = heightBeforeExpand else { return }
        heightBeforeExpand = nil
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
