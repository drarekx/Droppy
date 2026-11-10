import AppKit
import SwiftUI

/// Everything you can do with the files on a shelf. Shared by the shelf's "…" menu,
/// the right-click menu and the keyboard shortcuts.
enum ShelfAction: CaseIterable {
    case open, quickLook, reveal, copy, copyTo, moveTo, zip, share, airDrop, newShelf, remove, trash

    var title: String {
        switch self {
        case .open: return tr("Abrir")
        case .quickLook: return tr("Vista rápida")
        case .reveal: return tr("Mostrar en Finder")
        case .copy: return tr("Copiar")
        case .copyTo: return tr("Copiar a carpeta…")
        case .moveTo: return tr("Mover a carpeta…")
        case .zip: return tr("Comprimir en ZIP")
        case .share: return tr("Compartir…")
        case .airDrop: return tr("AirDrop…")
        case .newShelf: return tr("Pasar a una bandeja nueva")
        case .remove: return tr("Quitar de la bandeja")
        case .trash: return tr("Mover a la papelera")
        }
    }

    var symbol: String {
        switch self {
        case .open: return "arrow.up.forward.app"
        case .quickLook: return "eye"
        case .reveal: return "folder"
        case .copy: return "doc.on.doc"
        case .copyTo: return "folder.badge.plus"
        case .moveTo: return "arrow.right.doc.on.clipboard"
        case .zip: return "doc.zipper"
        case .share: return "square.and.arrow.up"
        case .airDrop: return "airplayaudio"
        case .newShelf: return "tray.2"
        case .remove: return "minus.circle"
        case .trash: return "trash"
        }
    }

    /// Menu layout; `nil` is a separator.
    static let menuLayout: [ShelfAction?] = [
        .open, .quickLook, .reveal, nil,
        .copy, .copyTo, .moveTo, .zip, nil,
        .share, .airDrop, nil,
        .newShelf, .remove, .trash,
    ]

    @MainActor
    func perform(on items: [ShelfItem], in shelf: Shelf) {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        switch self {
        case .open:
            for url in urls { NSWorkspace.shared.open(url) }
        case .quickLook:
            shelf.panel?.toggleQuickLook(urls)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        case .copyTo, .moveTo:
            FileOps.transfer(items, in: shelf, move: self == .moveTo)
        case .zip:
            FileOps.zip(items, in: shelf)
        case .share:
            guard let view = shelf.panel?.contentView else { return }
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: NSRect(x: view.bounds.midX - 1, y: 0, width: 2, height: 30),
                        of: view, preferredEdge: .minY)
        case .airDrop:
            NSApp.activate(ignoringOtherApps: true)
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case .newShelf:
            let ids = Set(items.map(\.id))
            let moved = shelf.items.filter { ids.contains($0.id) }
            shelf.remove(ids)
            let origin = shelf.panel.map { NSPoint(x: $0.frame.maxX + 20 + ShelfPanel.collapsedSize.width / 2, y: $0.frame.midY) }
            let new = Shelves.shared.newShelf(at: origin)
            new.items = moved
        case .remove:
            shelf.remove(Set(items.map(\.id)))
        case .trash:
            NSWorkspace.shared.recycle(urls) { trashed, error in
                MainActor.assumeIsolated {
                    shelf.remove(urls: Array(trashed.keys))
                    if let error { FileOps.alert(tr("No se pudo mover a la papelera"), error.localizedDescription) }
                }
            }
        }
    }

    /// AppKit version of the menu, for right-clicks on files.
    @MainActor
    static func menu(for items: [ShelfItem], in shelf: Shelf) -> NSMenu {
        let menu = NSMenu()
        for entry in menuLayout {
            guard let action = entry else { menu.addItem(.separator()); continue }
            let item = ClosureMenuItem(title: action.title) { action.perform(on: items, in: shelf) }
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }
}

/// SwiftUI version of the menu, for the shelf's "…" button.
struct ShelfMenuContent: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        let targets = shelf.actionTargets
        if shelf.expanded, !shelf.selection.isEmpty {
            Text(tr("%d seleccionados", targets.count))
        }
        ForEach(Array(ShelfAction.menuLayout.enumerated()), id: \.offset) { _, entry in
            if let action = entry {
                Button {
                    action.perform(on: targets, in: shelf)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
                .disabled(targets.isEmpty)
            } else {
                Divider()
            }
        }
        Divider()
        Button {
            Importer.add(from: .general, to: shelf)
        } label: {
            Label(tr("Pegar"), systemImage: "doc.on.clipboard")
        }
        Button {
            shelf.items = []
        } label: {
            Label(tr("Vaciar bandeja"), systemImage: "xmark.bin")
        }
        .disabled(shelf.items.isEmpty)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// File operations that take time or ask where to put things.
@MainActor
enum FileOps {
    /// "name.ext", or "name 2.ext", "name 3.ext"… if taken.
    nonisolated static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }

    /// Copy or move to a folder the user picks. Moved files leave the shelf (they've arrived)
    /// unless "keep after dragging" is on, in which case the shelf follows them.
    static func transfer(_ items: [ShelfItem], in shelf: Shelf, move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? tr("Mover aquí") : tr("Copiar aquí")
        panel.message = move ? tr("Elige adónde mover %d archivos.", items.count)
                             : tr("Elige adónde copiar %d archivos.", items.count)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        shelf.busy = move ? tr("Moviendo…") : tr("Copiando…")
        let sources = items.map(\.url)
        Task.detached {
            var done: [(URL, URL)] = []
            var failures: [String] = []
            for source in sources {
                let target = uniqueURL(in: folder, name: source.lastPathComponent)
                do {
                    if move {
                        try FileManager.default.moveItem(at: source, to: target)
                    } else {
                        try FileManager.default.copyItem(at: source, to: target)
                    }
                    done.append((source, target))
                } catch {
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let moved = done, errors = failures
            await MainActor.run {
                shelf.busy = nil
                if move {
                    if Settings.shared.removeAfterDrag {
                        shelf.remove(urls: moved.map(\.0))
                    } else {
                        let map = Dictionary(moved.map { ($0.0.standardizedFileURL.path, $0.1) }, uniquingKeysWith: { a, _ in a })
                        shelf.items = shelf.items.map { item in
                            guard let target = map[item.url.standardizedFileURL.path] else { return item }
                            return item.relocated(to: target)
                        }
                    }
                }
                if !errors.isEmpty {
                    alert(move ? tr("No se pudieron mover %d archivos", errors.count)
                               : tr("No se pudieron copiar %d archivos", errors.count),
                          errors.joined(separator: "\n"))
                }
            }
        }
    }

    /// Compresses the files into one ZIP that's added to the shelf.
    static func zip(_ items: [ShelfItem], in shelf: Shelf) {
        let sources = items.map(\.url)
        let folder = Shelves.clipsDirectory(for: shelf.id)
        let name = sources.count == 1
            ? sources[0].deletingPathExtension().lastPathComponent
            : tr("Archivos")
        shelf.busy = tr("Comprimiendo…")
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let zip = uniqueURL(in: folder, name: name + ".zip")
                if sources.count == 1 {
                    try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", sources[0].path, zip.path])
                } else {
                    // ditto takes one source: gather clones of the files in a temporary folder.
                    let staging = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(AppInfo.name)-zip-\(UUID().uuidString)", isDirectory: true)
                    let root = staging.appendingPathComponent(name, isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    for source in sources {
                        try FileManager.default.copyItem(at: source, to: uniqueURL(in: root, name: source.lastPathComponent))
                    }
                    try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, zip.path])
                }
                await MainActor.run {
                    shelf.busy = nil
                    shelf.add([zip], clips: true)
                }
            } catch {
                await MainActor.run {
                    shelf.busy = nil
                    alert(tr("No se pudo comprimir"), error.localizedDescription)
                }
            }
        }
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: AppInfo.name, code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? path : message])
        }
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
