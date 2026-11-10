import AppKit
import Combine
import Quartz
import SwiftUI

/// Floating window of one shelf. Non-activating, so it can be used while dragging from
/// another app without stealing focus; it still becomes key when clicked, for shortcuts.
final class ShelfPanel: NSPanel, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let collapsedSize = NSSize(width: 210, height: 236)
    static let expandedSize = NSSize(width: 290, height: 380)
    /// Docked shelf folded into a tab on the screen edge.
    static let tabSize = NSSize(width: 8, height: 72)
    static let dockSize = NSSize(width: 260, height: 340)
    /// Gap between the fixed shelf and the top or bottom of the screen in corner positions.
    static let dockMargin: CGFloat = 12

    let shelf: Shelf
    private var cancellables = Set<AnyCancellable>()
    private var previewURLs: [URL] = []

    @MainActor
    init(shelf: Shelf) {
        self.shelf = shelf
        super.init(contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .utilityWindow
        delegate = self

        let container = ShelfDropView(shelf: shelf)
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: ShelfView(shelf: shelf))
        // The window decides its size. With Auto Layout (or SwiftUI sizing), SwiftUI's minimum
        // sizes resize and move the window: the docked shelf stayed 252×268 instead of its
        // 8×72 tab, and opened 252×529 at the top instead of 260×340, centred.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        container.frame = NSRect(origin: .zero, size: Self.collapsedSize)
        hosting.frame = container.bounds
        container.addSubview(hosting)
        contentView = container
        shelf.panel = self

        if shelf.isDocked {
            collectionBehavior.insert(.stationary)
            container.trackMouse = true
            container.layer?.cornerRadius = 12
            shelf.$revealed.dropFirst().removeDuplicates().sink { [weak self] revealed in
                DispatchQueue.main.async { self?.slide(open: revealed) }
            }.store(in: &cancellables)
            Settings.shared.$dockEdge.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.layoutDock() }
            }.store(in: &cancellables)
            Settings.shared.$dockAlignment.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.layoutDock() }
            }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in self?.layoutDock() }
                .store(in: &cancellables)
        } else {
            shelf.$expanded.dropFirst().removeDuplicates().sink { [weak self] expanded in
                // After the change: @Published fires in willSet, and resizing now would render the old value.
                DispatchQueue.main.async { self?.resize(expanded: expanded) }
            }.store(in: &cancellables)
            if shelf.expanded { resize(expanded: true, animated: false) }
        }
    }

    // MARK: - Docked shelf

    /// Screen the docked shelf lives on: the one with the menu bar.
    static var dockScreen: NSScreen? { NSScreen.screens.first }

    /// Opening: the window takes its open size at once (animating a window frame with SwiftUI
    /// inside makes it jump) and the shelf slides out of the screen edge. Closing: the reverse.
    private func slide(open: Bool) {
        guard shelf.isDocked else { return }
        if open {
            layoutDock()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { shelf.contentShown = true }
        } else {
            withAnimation(.easeIn(duration: 0.18)) {
                shelf.contentShown = false
            } completion: { [weak self] in
                guard let self, !self.shelf.revealed else { return }
                self.layoutDock()
            }
        }
    }

    /// Tab, or the open shelf, on the chosen side; both stuck to the screen edge.
    func layoutDock() {
        guard shelf.isDocked else { return }
        let open = shelf.revealed || shelf.contentShown
        setFrame((open ? Self.openDockFrame() : Self.tabFrame()) ?? frame, display: true)
        // Rounded only on the side away from the screen edge.
        contentView?.layer?.cornerRadius = open ? 14 : 4
        contentView?.layer?.maskedCorners = Settings.shared.dockEdge == .left
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        invalidateShadow()
    }

    /// The folded tab, on the chosen side and position.
    static func tabFrame() -> NSRect? {
        guard let visible = dockScreen?.visibleFrame else { return nil }
        let settings = Settings.shared
        let size = tabSize
        let x = settings.dockEdge == .left ? visible.minX : visible.maxX - size.width
        let y: CGFloat
        switch settings.dockAlignment {
        case .top: y = visible.maxY - dockMargin - size.height
        case .center: y = visible.midY - size.height / 2
        case .bottom: y = visible.minY + dockMargin
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The open shelf: stuck to the tab's screen edge, vertically centred on the screen.
    static func openDockFrame() -> NSRect? {
        guard let visible = dockScreen?.visibleFrame else { return nil }
        let size = dockSize
        let x = Settings.shared.dockEdge == .left ? visible.minX : visible.maxX - size.width
        return NSRect(x: x, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Opened from a shortcut, the shake or the menu: stays open until the mouse has been on it,
    /// a click lands elsewhere, or Esc.
    var waitsForVisit = false

    /// Screen area where a drag reaching the edge opens the fixed shelf.
    static func dockTriggerZone() -> NSRect? {
        guard let screen = dockScreen?.frame, let visible = dockScreen?.visibleFrame else { return nil }
        let settings = Settings.shared
        let band: CGFloat = 260
        let x = settings.dockEdge == .left ? screen.minX : screen.maxX - 3
        let rect: NSRect
        switch settings.dockAlignment {
        case .top: rect = NSRect(x: x, y: visible.maxY - band, width: 3, height: band)
        case .center: rect = NSRect(x: x, y: visible.midY - band / 2, width: 3, height: band)
        case .bottom: rect = NSRect(x: x, y: visible.minY, width: 3, height: band)
        }
        return rect.insetBy(dx: 0, dy: -1)
    }

    /// Folds the docked shelf back into its tab once the mouse has left and nothing is going on.
    func scheduleDockCollapse() {
        guard shelf.isDocked, shelf.revealed else { return }
        // A default-mode timer doesn't fire while a menu is open.
        let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shelf.revealed else { return }
                let quickLook = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
                // Area between the tab and the open shelf counts as "on it", so the mouse can travel across.
                let keepArea = (Self.tabFrame().map { $0.union(self.frame) } ?? self.frame).insetBy(dx: -8, dy: -8)
                if keepArea.contains(NSEvent.mouseLocation) || self.waitsForVisit
                    || self.shelf.isTargeted || self.shelf.busy != nil || quickLook || NSEvent.pressedMouseButtons != 0 {
                    self.scheduleDockCollapse()
                    return
                }
                self.shelf.revealed = false
            }
        }
        RunLoop.main.add(timer, forMode: .default)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Placement

    /// Centre on a screen point (the mouse), kept inside the visible screen area.
    func place(centeredOn point: NSPoint) {
        let size = frame.size
        place(origin: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    func place(origin: NSPoint) {
        var rect = NSRect(origin: origin, size: frame.size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            rect.origin.x = min(max(rect.minX, visible.minX + 8), visible.maxX - rect.width - 8)
            rect.origin.y = min(max(rect.minY, visible.minY + 8), visible.maxY - rect.height - 8)
        }
        setFrame(rect, display: true)
    }

    /// Grows or shrinks keeping the top-left corner in place.
    private func resize(expanded: Bool, animated: Bool = true) {
        let size = expanded ? Self.expandedSize : Self.collapsedSize
        var rect = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            rect.origin.x = min(max(rect.minX, visible.minX + 8), visible.maxX - rect.width - 8)
            rect.origin.y = max(rect.minY, visible.minY + 8)
        }
        setFrame(rect, display: true)  // animating a frame with SwiftUI inside makes it jump
    }

    func animateIn() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func animateOut() {
        if previewURLs.count > 0, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }

    func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated { if !shelf.isDocked { Shelves.shared.scheduleSave() } }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated { shelf.refresh() }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            switch event.keyCode {
            case 53: // Esc
                if !shelf.selection.isEmpty { shelf.selection = [] } else { Shelves.shared.close(shelf) }
                if shelf.isDocked, !shelf.revealed { resignKey() }
            case 49: // Space
                toggleQuickLook(shelf.actionTargets.map(\.url))
            case 51, 117: // Delete, forward delete
                let targets = shelf.actionTargets
                if shelf.expanded, !shelf.selection.isEmpty {
                    ShelfAction.remove.perform(on: targets, in: shelf)
                } else {
                    NSSound.beep()
                }
            case 36, 76: // Return
                ShelfAction.open.perform(on: shelf.actionTargets, in: shelf)
            default:
                super.keyDown(with: event)
            }
        }
    }

    override func performClose(_ sender: Any?) {
        MainActor.assumeIsolated { Shelves.shared.close(shelf) }
    }

    @objc func copy(_ sender: Any?) {
        MainActor.assumeIsolated { ShelfAction.copy.perform(on: shelf.actionTargets, in: shelf) }
    }

    @objc func paste(_ sender: Any?) {
        MainActor.assumeIsolated { Importer.add(from: .general, to: shelf) }
    }

    @objc override func selectAll(_ sender: Any?) {
        MainActor.assumeIsolated {
            shelf.expanded = true
            shelf.selection = Set(shelf.items.map(\.id))
        }
    }

    @objc func deleteSelection(_ sender: Any?) {
        MainActor.assumeIsolated { ShelfAction.trash.perform(on: shelf.actionTargets, in: shelf) }
    }

    // MARK: - Quick Look

    func toggleQuickLook(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible, previewURLs == urls {
            panel.orderOut(nil)
            return
        }
        previewURLs = urls
        makeKey()
        NSApp.activate(ignoringOtherApps: true)
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }
}

/// Root view of a shelf window: receives drops of files, promised files, images, text and links.
final class ShelfDropView: NSView {
    private let shelf: Shelf
    /// Docked shelf: opens when the mouse enters, folds when it leaves.
    var trackMouse = false

    @MainActor
    init(shelf: Shelf) {
        self.shelf = shelf
        super.init(frame: .zero)
        registerForDraggedTypes(Importer.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard trackMouse else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated {
            (window as? ShelfPanel)?.waitsForVisit = false
            Shelves.shared.revealDock()
        }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { (window as? ShelfPanel)?.scheduleDockCollapse() }
    }

    /// Drags that start on this same shelf are ignored, so dragging inside it does nothing.
    private func isOwnDrag(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSView)?.window === window
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isOwnDrag(sender) else { return [] }
        MainActor.assumeIsolated {
            shelf.isTargeted = true
            if shelf.isDocked { Shelves.shared.revealDock() }
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOwnDrag(sender) ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated {
            shelf.isTargeted = false
            (window as? ShelfPanel)?.scheduleDockCollapse()
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        MainActor.assumeIsolated { shelf.isTargeted = false }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isOwnDrag(sender) else { return false }
        return MainActor.assumeIsolated {
            shelf.isTargeted = false
            (window as? ShelfPanel)?.scheduleDockCollapse()
            return Importer.add(from: sender.draggingPasteboard, to: shelf)
        }
    }
}
