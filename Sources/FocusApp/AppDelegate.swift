import AppKit
import Combine
import Carbon.HIToolbox
import SwiftUI
import FocusCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: QueueModel!
    private var fade: FadeController!
    private var panel: FocusPanel!
    private var statusItem: NSStatusItem!
    private var keyMonitor: Any?
    private var settingsWindow: NSWindow?
    private var settingsHost: NSHostingController<SettingsView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            model = QueueModel(store: try Store())
        } catch {
            let alert = NSAlert()
            alert.messageText = "Focus could not open its database"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        fade = FadeController(model: model)

        let view = PanelView(
            model: model,
            fade: fade,
            onExpand: { [weak self] delta in self?.panel?.grow(by: delta) },
            onCollapse: { [weak self] in self?.panel?.restoreHeight() },
            onSettings: { [weak self] in self?.openSettings() },
            onOpen: { [weak self] url in self?.openItem(url) }
        )
        panel = FocusPanel(content: view)

        // Return on the focused panel opens the add field. The panel only gets keys after
        // you click it, so other apps never lose Return. Ignored while a text field has
        // focus (the field editor is an NSText), so typing and submitting work normally.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel,
                  event.keyCode == 36 || event.keyCode == 76,   // Return, keypad Enter
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(self.panel.firstResponder is NSText) else { return event }
            self.fade.wake()
            self.model.requestAdd()
            return nil
        }
        fade.panel = panel
        // Hiding is cosmetic: anything that lights up brings a hidden panel back so it's seen.
        alertObserver = model.$alertTick.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.returnFromReply() }
        }
        setupStatusItem()

        panel.orderFrontRegardless()
        fade.start()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Focus")

        let menu = NSMenu()
        // No key equivalents: a status-item menu's shortcuts only work while it is open, and
        // otherwise the keys go to the front app (⌘F searched in Slack).
        menu.addItem(item("Show / Hide Focus  (⌃⌥F, or middle-click)", #selector(togglePanel), ""))
        menu.addItem(item("Reset Position", #selector(resetPosition), ""))
        menu.addItem(item("Settings…", #selector(openSettings), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Focus", #selector(quit), ""))
        statusItem.menu = menu
        // Middle-click on the icon shows/hides the panel. The status item's button doesn't
        // pass middle clicks to its action, so watch for them directly.
        middleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self, event.window === self.statusItem.button?.window else { return event }
            self.togglePanel()
            return nil
        }
        // ⌃⌥F from any app shows/hides the panel.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.togglePanel() }
        }
    }

    private var middleClickMonitor: Any?
    private var hotKey: HotKey?
    private var alertObserver: AnyCancellable?

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    // MARK: - Hide while replying

    /// The app you're replying in. Links often pass through another app first (Slack
    /// links open in the browser, which hands them to Slack), so for a few seconds after
    /// the click the newest front app becomes the target; after that, leaving it brings
    /// the panel back.
    private var replyTarget: String?
    private var replyOpenedAt = Date.distantPast
    private let handOffSeconds: TimeInterval = 4
    private var hidingForReply = false
    private var returnTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// Opens an item and gets out of the way: the panel hides until you switch away from
    /// the app that opened it, or the configured minutes pass (tab switches inside a
    /// browser aren't visible to macOS, hence the timer).
    private func openItem(_ url: URL) {
        NSWorkspace.shared.open(url)
        let minutes = model.settings.hideAfterOpenMinutes
        guard minutes > 0 else { return }
        replyTarget = nil
        replyOpenedAt = Date()
        hidingForReply = true
        panel.orderOut(nil)
        returnTimer?.invalidate()
        returnTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnFromReply() }
        }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { self?.appActivated(id) }
            }
        }
    }

    private func appActivated(_ bundleId: String?) {
        guard hidingForReply, let bundleId, bundleId != Bundle.main.bundleIdentifier else { return }
        // Still handing off (browser -> Slack): the newest app is where you'll reply.
        if Date().timeIntervalSince(replyOpenedAt) < handOffSeconds || replyTarget == nil {
            replyTarget = bundleId
            return
        }
        if bundleId != replyTarget { returnFromReply() }
    }

    /// Puts the panel back where it was.
    private func returnFromReply() {
        returnTimer?.invalidate()
        returnTimer = nil
        replyTarget = nil
        hidingForReply = false
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            returnFromReply()
            fade.wake()
        }
    }

    @objc private func resetPosition() {
        panel.placeTopRight()
        fade.wake()
    }

    @objc private func openSettings() {
        let makeView = { [weak self] (height: CGFloat?) in
            SettingsView(model: self!.model, onResetPosition: { self?.resetPosition() }, height: height)
        }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: makeView(nil))
            host.sizingOptions = []   // sized explicitly below, so it can be capped to the screen
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = "Focus Settings"
            window.isReleasedWhenClosed = false
            settingsWindow = window
            settingsHost = host
        }
        guard let window = settingsWindow, let host = settingsHost else { return }
        // Natural height, capped to the screen (the form scrolls when capped), placed
        // centered horizontally just below the menu bar so nothing opens off-screen.
        let visible = (NSScreen.main ?? window.screen)?.visibleFrame ?? .zero
        host.rootView = makeView(nil)
        // fittingSize is 0x0 for this view, so ask SwiftUI for the size at the fixed width.
        var natural = host.sizeThatFits(in: NSSize(width: 880, height: 100_000))
        if natural.width < 100 || natural.height < 100 || natural.height >= 100_000 {
            natural = NSSize(width: 880, height: visible.height)   // fall back to capped height
        }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let cap = visible.height - chrome - 40
        let height = min(natural.height, cap)
        host.rootView = makeView(natural.height > cap ? height : nil)
        window.setContentSize(NSSize(width: natural.width, height: height))
        // Centered, unless that would sit under the always-on-top panel: then beside it,
        // on whichever side has room (left first, since the panel defaults to the right).
        var x = visible.midX - window.frame.width / 2
        if panel.isVisible {
            let p = panel.frame, w = window.frame.width, gap: CGFloat = 16
            if x < p.maxX && x + w > p.minX {
                if p.minX - gap - w >= visible.minX { x = p.minX - gap - w }
                else if p.maxX + gap + w <= visible.maxX { x = p.maxX + gap }
                else { x = p.minX - gap - w < visible.minX ? visible.minX : x }   // no room: keep on screen
            }
        }
        window.setFrameTopLeftPoint(NSPoint(x: x, y: visible.maxY - 20))
        // A menubar-only app is never frontmost on its own; bring it forward for the window.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.commitPendingDone()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
