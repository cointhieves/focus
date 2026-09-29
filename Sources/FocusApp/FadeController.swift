import AppKit
import SwiftUI

/// Decides whether the panel is "awake" (full opacity, clickable) or faded (click-through).
/// Hover is detected by polling the global mouse position, because a click-through
/// window receives no mouse events of its own.
@MainActor
final class FadeController: ObservableObject {
    @Published private(set) var awake = true

    var idleOpacity: Double { model.settings.idleOpacity }
    /// How long the panel stays awake on launch or when shown from the menu.
    var wakeSeconds: TimeInterval = 30
    /// How long the panel stays awake after the mouse leaves it.
    var hoverLingerSeconds: TimeInterval { model.settings.fadeDelaySeconds }

    weak var panel: NSPanel?
    private let model: QueueModel
    private var wakeUntil = Date().addingTimeInterval(30)
    private var timer: Timer?
    // Previous tick's button state, to know where a press started.
    private var wasButtonDown = false
    private var pressStartedOnPanel = false

    init(model: QueueModel) { self.model = model }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Wake immediately, e.g. when the panel is shown from the menu.
    func wake() { wakeUntil = Date().addingTimeInterval(wakeSeconds) }

    private func tick() {
        guard let panel else { return }
        // Pops no longer wake the whole panel: the moved row lights up on its own
        // (see ItemRow.highlighted), and the rest of the panel stays faded.
        // The window's resize handles sit slightly outside its frame, so treat a
        // margin around it as hover. Otherwise the edge click falls through to
        // whatever is behind the panel.
        let hotZone = panel.frame.insetBy(dx: -10, dy: -10)
        let hovering = panel.isVisible && hotZone.contains(NSEvent.mouseLocation)
        // Never go click-through mid-drag, or a resize/move would be cut off.
        // Only a press that STARTED on the panel counts; clicks in other apps must not
        // keep the panel awake.
        let buttonDown = NSEvent.pressedMouseButtons != 0
        if buttonDown && !wasButtonDown { pressStartedOnPanel = hovering }
        if !buttonDown { pressStartedOnPanel = false }
        wasButtonDown = buttonDown
        let dragging = awake && buttonDown && pressStartedOnPanel
        if hovering || dragging {
            // Keep extending the linger window while the mouse is on the panel.
            wakeUntil = max(wakeUntil, Date().addingTimeInterval(hoverLingerSeconds))
        }
        let shouldWake = hovering || dragging || Date() < wakeUntil

        panel.ignoresMouseEvents = !shouldWake
        if shouldWake != awake {
            withAnimation(.easeInOut(duration: 0.4)) { awake = shouldWake }
        }
    }
}
