import AppKit
import SwiftUI

/// Transparent AppKit layer that drags files out of a shelf (several at once, which
/// SwiftUI's `onDrag` can't), and reports clicks, double-clicks and right-clicks.
struct FileDragArea: NSViewRepresentable {
    var urls: () -> [URL]
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onDragEnded: ([URL], NSDragOperation) -> Void = { _, _ in }
    var menu: () -> NSMenu? = { nil }

    func makeNSView(context: Context) -> FileDragView { FileDragView() }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragEnded = onDragEnded
        view.menuProvider = menu
    }
}

final class FileDragView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onDragEnded: ([URL], NSDragOperation) -> Void = { _, _ in }
    var menuProvider: () -> NSMenu? = { nil }

    private var mouseDownEvent: NSEvent?
    private var dragging = false
    private var draggedURLs: [URL] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragging = false
        if event.clickCount == 2 { onDoubleClick() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownEvent else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        let urls = urls()
        guard !urls.isEmpty else { return }
        dragging = true
        draggedURLs = urls
        let local = convert(start.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.prefix(60).enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = Thumbnails.cachedImage(for: url) ?? NSWorkspace.shared.icon(forFile: url.path)
            let side: CGFloat = 64
            let offset = CGFloat(min(index, 4)) * 6
            item.setDraggingFrame(NSRect(x: local.x - side / 2 + offset, y: local.y - side / 2 - offset,
                                         width: side, height: side), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: start, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging, event.clickCount < 2 { onClick(event.modifierFlags) }
        mouseDownEvent = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }

    // MARK: NSDraggingSource

    /// Outside the app: copy, move (Finder's default on the same disk; ⌘ forces it), link or Trash.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : [.copy, .move, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        mouseDownEvent = nil
        // Dropped back on the same shelf: nothing happened.
        if let frame = window?.frame, frame.contains(screenPoint) { return }
        onDragEnded(draggedURLs, operation)
    }
}
