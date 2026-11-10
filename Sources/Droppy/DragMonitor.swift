import AppKit

/// Watches mouse drags in other apps and opens a shelf at the mouse when the user
/// shakes it (quick left-right movements) or presses the chosen modifier key.
///
/// Global monitors for mouse events need no special permission. A drag only counts
/// when it carries something: the drag pasteboard changes when a drag of files, text
/// or images starts, but not when moving windows or selecting with the mouse.
@MainActor
final class DragMonitor {
    static let shared = DragMonitor()

    private var monitor: Any?
    private var pasteboardCount = 0
    private var carriesContent = false
    private var triggered = false

    // Shake tracking
    private var lastX: CGFloat = 0
    private var direction = 0
    private var segmentStart: CGFloat = 0
    private var reversals: [TimeInterval] = []

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { DragMonitor.shared.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pasteboardCount = NSPasteboard(name: .drag).changeCount
            reset()
        case .leftMouseDragged:
            dragged(event)
        case .leftMouseUp:
            reset()
        default:
            break
        }
    }

    private func reset() {
        carriesContent = false
        triggered = false
        direction = 0
        reversals = []
        lastX = NSEvent.mouseLocation.x
        segmentStart = lastX
    }

    private func dragged(_ event: NSEvent) {
        guard !triggered else { return }
        if !carriesContent {
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != pasteboardCount, !(pasteboard.types ?? []).isEmpty else { return }
            carriesContent = true
            reset()
            carriesContent = true
        }
        let settings = Settings.shared
        // Reaching the left edge of the screen opens the docked shelf (shaking still works too).
        let mouse = NSEvent.mouseLocation
        if settings.dockEnabled, let screen = ShelfPanel.dockScreen?.frame,
           mouse.x <= screen.minX + 3, mouse.y >= screen.minY, mouse.y <= screen.maxY {
            Shelves.shared.revealDock()
        }
        if let flag = settings.triggerModifier.flag, event.modifierFlags.contains(flag) {
            trigger()
            return
        }
        guard settings.shakeEnabled else { return }

        let x = NSEvent.mouseLocation.x
        let dx = x - lastX
        guard abs(dx) >= 1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let newDirection = dx > 0 ? 1 : -1
        if newDirection != direction {
            if direction != 0, abs(lastX - segmentStart) >= settings.shakeSensitivity.distance {
                reversals.append(now)
            }
            segmentStart = lastX
            direction = newDirection
        }
        lastX = x
        reversals.removeAll { now - $0 > settings.shakeSensitivity.window }
        if reversals.count >= settings.shakeSensitivity.reversals { trigger() }
    }

    private func trigger() {
        triggered = true
        Shelves.shared.shelfForDrag(at: NSEvent.mouseLocation)
    }
}
