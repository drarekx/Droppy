import AppKit
import Combine

/// Open and recent shelves, their windows and `shelves.json`.
@MainActor
final class Shelves: ObservableObject {
    static let shared = Shelves()
    static let maxRecent = 15

    @Published private(set) var open: [Shelf] = []
    /// Closed shelves that still had files, newest first.
    @Published private(set) var recent: [Shelf] = []
    /// Fixed shelf on the left edge of the screen; exists even when hidden in Settings.
    private(set) var docked = Shelf(docked: true)

    private var panels: [UUID: ShelfPanel] = [:]
    private var observers: [UUID: [AnyCancellable]] = [:]
    private var saveScheduled = false
    private var refreshTimer: Timer?

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    private static var indexURL: URL { supportDirectory.appendingPathComponent("shelves.json") }

    /// Where text, images and links dropped on a shelf are written as files.
    static func clipsDirectory(for id: UUID) -> URL {
        supportDirectory.appendingPathComponent("Clips", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Lifecycle

    func load() {
        defer {
            startRefreshing()
            setDockVisible(Settings.shared.dockEnabled)
        }
        guard let data = try? Data(contentsOf: Self.indexURL),
              let stored = try? JSONDecoder().decode([StoredShelf].self, from: data) else { return }
        for entry in stored {
            if entry.docked == true {
                docked = Shelf(id: entry.id, created: entry.created, items: entry.items, docked: true)
                docked.refresh()
                continue
            }
            let shelf = Shelf(id: entry.id, created: entry.created, items: entry.items, name: entry.name)
            shelf.refresh()
            guard !shelf.items.isEmpty || shelf.isNamed else { removeClips(of: shelf); continue }
            if entry.open {
                show(shelf, at: entry.origin.map { NSPoint(x: $0.x, y: $0.y) }, centered: false)
            } else {
                observe(shelf)
                recent.append(shelf)
            }
        }
        recent = Array(recent.prefix(Self.maxRecent))
    }

    /// Open shelves follow their files (moved in Finder, deleted…) every few seconds.
    private func startRefreshing() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                for shelf in Shelves.shared.open { shelf.refresh() }
                Shelves.shared.docked.refresh()
            }
        }
    }

    // MARK: - Shelves

    /// New shelf with `urls`, centred on `point` (the mouse by default).
    @discardableResult
    func newShelf(with urls: [URL] = [], clips: Bool = false, at point: NSPoint? = nil) -> Shelf {
        let shelf = Shelf()
        shelf.add(urls, clips: clips)
        show(shelf, at: point ?? NSEvent.mouseLocation, centered: true)
        return shelf
    }

    /// New shelf from whatever is in `pasteboard` (files, text, images, links).
    func newShelf(from pasteboard: NSPasteboard, at point: NSPoint? = nil) {
        let shelf = newShelf(at: point)
        Importer.add(from: pasteboard, to: shelf)
    }

    /// Shelf for a drag that is in progress: reuses an empty open shelf, else makes one.
    func shelfForDrag(at point: NSPoint) {
        if let empty = open.last(where: { $0.items.isEmpty && !$0.isNamed }), let panel = panels[empty.id] {
            panel.place(centeredOn: point)
            panel.orderFrontRegardless()
            return
        }
        newShelf(at: point)
    }

    func show(_ shelf: Shelf, at point: NSPoint? = nil, centered: Bool = true) {
        recent.removeAll { $0.id == shelf.id }
        if let panel = panels[shelf.id] {
            panel.orderFrontRegardless()
            return
        }
        let panel = ShelfPanel(shelf: shelf)
        panels[shelf.id] = panel
        if !open.contains(where: { $0.id == shelf.id }) { open.append(shelf) }
        observe(shelf)
        if let point {
            if centered { panel.place(centeredOn: point) } else { panel.place(origin: point) }
        } else {
            panel.place(centeredOn: NSEvent.mouseLocation)
        }
        panel.orderFrontRegardless()
        panel.animateIn()
        scheduleSave()
    }

    // MARK: - Docked shelf

    func setDockVisible(_ visible: Bool) {
        if visible {
            guard panels[docked.id] == nil else { return }
            let panel = ShelfPanel(shelf: docked)
            panels[docked.id] = panel
            observe(docked)
            panel.layoutDock()
            panel.orderFrontRegardless()
        } else {
            panels.removeValue(forKey: docked.id)?.orderOut(nil)
        }
    }

    /// Opens the docked shelf (mouse over it, or a drag reaching the screen edge).
    /// `sticky`: opened by a shortcut, the shake or the menu rather than the mouse over the tab.
    func revealDock(sticky: Bool = false) {
        guard Settings.shared.dockEnabled else { return }
        if sticky { dockPanel?.waitsForVisit = true }
        guard !docked.revealed else { return }
        docked.revealed = true
        dockPanel?.orderFrontRegardless()
        dockPanel?.scheduleDockCollapse()
    }

    func toggleDock() {
        if docked.revealed { docked.revealed = false } else { revealDock(sticky: true) }
    }

    /// A click in another app folds the open docked shelf.
    func dockClickedOutside(at point: NSPoint) {
        guard docked.revealed, let panel = dockPanel, !panel.frame.contains(point) else { return }
        panel.waitsForVisit = false
        docked.revealed = false
    }

    var dockPanel: ShelfPanel? { panels[docked.id] }

    /// Closes the window. A shelf with files goes to "Recent shelves".
    func close(_ shelf: Shelf) {
        if shelf.isDocked {
            shelf.revealed = false
            return
        }
        panels.removeValue(forKey: shelf.id)?.animateOut()
        open.removeAll { $0.id == shelf.id }
        shelf.selection = []
        if (shelf.items.isEmpty && !shelf.isNamed) || !Settings.shared.keepRecent {
            discard(shelf)
        } else {
            recent.removeAll { $0.id == shelf.id }
            recent.insert(shelf, at: 0)
            for old in recent.dropFirst(Self.maxRecent) { discard(old) }
            recent = Array(recent.prefix(Self.maxRecent))
        }
        scheduleSave()
    }

    func closeAll() {
        for shelf in open { close(shelf) }
    }

    func reopen(_ shelf: Shelf) {
        shelf.refresh()
        guard !shelf.items.isEmpty || shelf.isNamed else {
            recent.removeAll { $0.id == shelf.id }
            discard(shelf)
            scheduleSave()
            return
        }
        show(shelf)
    }

    func clearRecent() {
        for shelf in recent { discard(shelf) }
        recent = []
        scheduleSave()
    }

    func bringAllToFront() {
        for shelf in open { panels[shelf.id]?.orderFrontRegardless() }
    }

    /// The shelf whose window is key, if any.
    var keyShelf: Shelf? { open.first { panels[$0.id]?.isKeyWindow == true } }

    private func discard(_ shelf: Shelf) {
        observers.removeValue(forKey: shelf.id)
        removeClips(of: shelf)
    }

    /// Clips are files Droppy wrote itself; whatever was dragged out of the folder is already elsewhere.
    private func removeClips(of shelf: Shelf) {
        try? FileManager.default.removeItem(at: Self.clipsDirectory(for: shelf.id))
    }

    // MARK: - Persistence

    private func observe(_ shelf: Shelf) {
        let names = shelf.$name.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSave() }
        }
        let items = shelf.$items.dropFirst().sink { [weak self, weak shelf] items in
            MainActor.assumeIsolated {
                guard let self, let shelf else { return }
                if !shelf.isDocked, !shelf.isNamed, items.isEmpty, Settings.shared.closeWhenEmpty, self.panels[shelf.id] != nil,
                   !shelf.isTargeted, shelf.busy == nil {
                    // Let the drag-out animation finish first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if shelf.items.isEmpty, !shelf.isTargeted { self.close(shelf) }
                    }
                }
                self.scheduleSave()
            }
        }
        observers[shelf.id] = [names, items]
    }

    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        // Empty shelves are kept only if they have a name.
        var stored = open.filter { !$0.items.isEmpty || $0.isNamed }.map { shelf in
            StoredShelf(id: shelf.id, created: shelf.created, items: shelf.items, open: true,
                        origin: panels[shelf.id].map { StoredShelf.Point(x: $0.frame.minX, y: $0.frame.minY) },
                        docked: nil, name: shelf.name)
        }
        stored.insert(StoredShelf(id: docked.id, created: docked.created, items: docked.items,
                                  open: false, origin: nil, docked: true, name: nil), at: 0)
        stored += recent.map {
            StoredShelf(id: $0.id, created: $0.created, items: $0.items, open: false, origin: nil, docked: nil, name: $0.name)
        }
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: Self.indexURL, options: .atomic)
        } catch {
            NSLog("Droppy: couldn't save shelves: \(error)")
        }
    }

    private struct StoredShelf: Codable {
        struct Point: Codable { var x: Double; var y: Double }
        let id: UUID
        let created: Date
        let items: [ShelfItem]
        let open: Bool
        let origin: Point?
        /// Optional so older files still decode.
        let docked: Bool?
        let name: String?
    }
}
