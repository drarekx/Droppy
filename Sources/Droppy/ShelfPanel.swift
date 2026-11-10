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
    static let tabSize = NSSize(width: 16, height: 150)
    static let dockWidth: CGFloat = 300

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
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
        shelf.panel = self

        if shelf.isDocked {
            collectionBehavior.insert(.stationary)
            container.trackMouse = true
            // Rounded only on the side away from the screen edge.
            container.layer?.cornerRadius = 14
            container.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            shelf.$revealed.dropFirst().removeDuplicates().sink { [weak self] _ in
                self?.layoutDock(animated: true)
            }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in self?.layoutDock() }
                .store(in: &cancellables)
        } else {
            shelf.$expanded.dropFirst().removeDuplicates().sink { [weak self] expanded in
                self?.resize(expanded: expanded)
            }.store(in: &cancellables)
            if shelf.expanded { resize(expanded: true, animated: false) }
        }
    }

    // MARK: - Docked shelf

    /// Screen the docked shelf lives on: the one with the menu bar.
    static var dockScreen: NSScreen? { NSScreen.screens.first }

    /// Tab on the left edge, or the open shelf next to it.
    func layoutDock(animated: Bool = false) {
        guard shelf.isDocked, let visible = Self.dockScreen?.visibleFrame else { return }
        let rect: NSRect
        if shelf.revealed {
            let height = min(visible.height - 60, 620)
            rect = NSRect(x: visible.minX, y: visible.midY - height / 2, width: Self.dockWidth, height: height)
        } else {
            rect = NSRect(x: visible.minX, y: visible.midY - Self.tabSize.height / 2,
                          width: Self.tabSize.width, height: Self.tabSize.height)
        }
        setFrame(rect, display: true, animate: animated)
    }

    /// Folds the docked shelf back into its tab once the mouse has left and nothing is going on.
    func scheduleDockCollapse() {
        guard shelf.isDocked, shelf.revealed else { return }
        // A default-mode timer doesn't fire while a menu is open.
        let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shelf.revealed else { return }
                let quickLook = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
                if self.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
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
        setFrame(rect, display: true, animate: animated)
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
        MainActor.assumeIsolated { Shelves.shared.revealDock() }
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
