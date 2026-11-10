import AppKit
import Combine
import SwiftUI

/// Subfolder a file goes to when a folder is sorted by kind.
enum OrganizeCategory: String, CaseIterable, Identifiable, Codable {
    case images, pdf, documents, spreadsheets, presentations, videos, audio, archives, installers, code, apps, other
    var id: String { rawValue }

    /// Always Catalan, whatever the app language, so the same folders keep being used.
    var folderName: String {
        switch self {
        case .images: return "Imatges"
        case .pdf: return "PDF"
        case .documents: return "Documents"
        case .spreadsheets: return "Fulls de càlcul"
        case .presentations: return "Presentacions"
        case .videos: return "Vídeos"
        case .audio: return "Àudio"
        case .archives: return "Comprimits"
        case .installers: return "Instal·ladors"
        case .code: return "Codi"
        case .apps: return "Apps"
        case .other: return "Altres"
        }
    }

    var symbol: String {
        switch self {
        case .images: return "photo"
        case .pdf: return "doc.richtext"
        case .documents: return "doc.text"
        case .spreadsheets: return "tablecells"
        case .presentations: return "rectangle.on.rectangle"
        case .videos: return "film"
        case .audio: return "waveform"
        case .archives: return "archivebox"
        case .installers: return "shippingbox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .apps: return "app"
        case .other: return "doc"
        }
    }

    /// `nil` for plain folders, which are never moved.
    init?(url: URL) {
        if ["dmg", "pkg", "mpkg", "iso"].contains(url.pathExtension.lowercased()) {
            self = .installers
            return
        }
        switch FileCategory(url: url) {
        case .folder: return nil
        case .image: self = .images
        case .pdf: self = .pdf
        case .document: self = .documents
        case .spreadsheet: self = .spreadsheets
        case .presentation: self = .presentations
        case .video: self = .videos
        case .audio: self = .audio
        case .archive: self = .archives
        case .code: self = .code
        case .app: self = .apps
        case .other: self = .other
        }
    }
}

/// What sorting a folder would move, worked out before touching anything.
struct OrganizePlan {
    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let category: OrganizeCategory
        let size: Int64
    }

    let folder: URL
    var entries: [Entry] = []
    /// Files left for later because they are still arriving (automatic mode).
    var waiting = 0

    func entries(in category: OrganizeCategory) -> [Entry] { entries.filter { $0.category == category } }
    var categories: [OrganizeCategory] { OrganizeCategory.allCases.filter { c in entries.contains { $0.category == c } } }
}

struct OrganizeMove: Codable, Hashable {
    let from: URL
    let to: URL
}

/// One sorting run, kept so it can be undone.
struct OrganizeBatch: Codable, Identifiable {
    let id: UUID
    let date: Date
    let folder: URL
    let automatic: Bool
    var moves: [OrganizeMove]
    /// Subfolders this run created (removed on undo if they end up empty).
    var createdFolders: [URL]
}

/// Sorts the files of a folder into subfolders by kind, by hand or automatically as files arrive.
@MainActor
final class Organizer: ObservableObject {
    static let shared = Organizer()
    static let maxHistory = 30

    @Published private(set) var history: [OrganizeBatch] = []
    @Published private(set) var working = false

    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var window: NSWindow?

    var lastBatch: OrganizeBatch? { history.last }

    private static var historyURL: URL { Shelves.supportDirectory.appendingPathComponent("organize-history.json") }

    /// Extensions of downloads that haven't finished (Chrome, Safari, Firefox, Opera…).
    nonisolated static let incompleteExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]

    func load() {
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([OrganizeBatch].self, from: data) {
            history = saved
        }
        updateWatcher()
    }

    // MARK: - Plan

    /// Files at the top level of `folder` and where they'd go. Folders, hidden files and
    /// downloads in progress are left alone. `since`: only files added to the folder after it
    /// (automatic mode), and not while they may still be being written.
    nonisolated static func plan(folder: URL, excluded: Set<OrganizeCategory>, since: Date? = nil) -> OrganizePlan {
        var plan = OrganizePlan(folder: folder)
        let keys: [URLResourceKey] = [.isHiddenKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
                                      .addedToDirectoryDateKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                          options: [.skipsHiddenFiles]) else { return plan }
        let names = Set(contents.map(\.lastPathComponent))
        let now = Date()
        for url in contents {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true { continue }
            if incompleteExtensions.contains(url.pathExtension.lowercased()) { continue }
            // Firefox and others keep the final name next to "name.part" while downloading.
            if incompleteExtensions.contains(where: { names.contains(url.lastPathComponent + "." + $0) }) { continue }
            guard let category = OrganizeCategory(url: url), !excluded.contains(category) else { continue }
            let size = Int64(values?.fileSize ?? 0)
            if let since {
                let added = values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
                if added <= since { continue }
                let modified = values?.contentModificationDate ?? added
                // Still being written, or an empty placeholder of a download that just started.
                if now.timeIntervalSince(modified) < 5 || (size == 0 && now.timeIntervalSince(added) < 120) {
                    plan.waiting += 1
                    continue
                }
            }
            plan.entries.append(.init(url: url, category: category, size: size))
        }
        plan.entries.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        return plan
    }

    // MARK: - Run and undo

    /// Moves the entries into their subfolders. Name clashes become "name 2.ext".
    nonisolated static func perform(_ entries: [OrganizePlan.Entry], in folder: URL, automatic: Bool) -> (OrganizeBatch, [String]) {
        var batch = OrganizeBatch(id: UUID(), date: Date(), folder: folder, automatic: automatic, moves: [], createdFolders: [])
        var failures: [String] = []
        let manager = FileManager.default
        for entry in entries {
            let target = folder.appendingPathComponent(entry.category.folderName, isDirectory: true)
            do {
                if !manager.fileExists(atPath: target.path) {
                    try manager.createDirectory(at: target, withIntermediateDirectories: false)
                    batch.createdFolders.append(target)
                }
                let destination = FileOps.uniqueURL(in: target, name: entry.url.lastPathComponent)
                try manager.moveItem(at: entry.url, to: destination)
                batch.moves.append(OrganizeMove(from: entry.url, to: destination))
            } catch {
                failures.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (batch, failures)
    }

    /// Sorts and records the run. Returns the run and the files that couldn't be moved.
    @discardableResult
    func organize(_ entries: [OrganizePlan.Entry], in folder: URL, automatic: Bool = false) async -> (OrganizeBatch, [String]) {
        working = true
        defer { working = false }
        let result = await Task.detached { Self.perform(entries, in: folder, automatic: automatic) }.value
        if !result.0.moves.isEmpty { record(result.0) }
        return result
    }

    /// Puts the files of the last run back where they were. Files moved or deleted since are skipped.
    func undoLast() async -> (restored: Int, failures: [String]) {
        guard let batch = history.last else { return (0, []) }
        working = true
        defer { working = false }
        let result = await Task.detached { () -> (Int, [String]) in
            let manager = FileManager.default
            var restored = 0
            var failures: [String] = []
            for move in batch.moves.reversed() {
                guard manager.fileExists(atPath: move.to.path) else {
                    failures.append(move.to.lastPathComponent)
                    continue
                }
                let back = manager.fileExists(atPath: move.from.path)
                    ? FileOps.uniqueURL(in: move.from.deletingLastPathComponent(), name: move.from.lastPathComponent)
                    : move.from
                do {
                    try manager.moveItem(at: move.to, to: back)
                    restored += 1
                } catch {
                    failures.append("\(move.to.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // Remove the subfolders this run created, only if nothing else is in them.
            for folder in batch.createdFolders {
                let left = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != ".DS_Store" }
                if left.isEmpty { try? manager.removeItem(at: folder) }
            }
            return (restored, failures)
        }.value
        history.removeLast()
        saveHistory()
        // Files put back in the watched folder must not be sorted again straight away.
        if Settings.shared.autoOrganize, batch.folder.standardizedFileURL == Settings.shared.organizeFolder.standardizedFileURL {
            Settings.shared.autoOrganizeSince = Date()
        }
        return result
    }

    private func record(_ batch: OrganizeBatch) {
        history.append(batch)
        if history.count > Self.maxHistory { history.removeFirst(history.count - Self.maxHistory) }
        saveHistory()
    }

    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: Shelves.supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: Self.historyURL, options: .atomic)
        } catch {
            NSLog("Droppy: couldn't save organize history: \(error)")
        }
    }

    // MARK: - Automatic

    /// Watches the chosen folder while "sort automatically" is on.
    func updateWatcher() {
        source?.cancel()
        source = nil
        pending?.cancel()
        let settings = Settings.shared
        guard settings.autoOrganize else { return }
        let fd = open(settings.organizeFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleAutomatic(after: 3) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        scheduleAutomatic(after: 2)
    }

    private func scheduleAutomatic(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.runAutomatic() }
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func runAutomatic() async {
        let settings = Settings.shared
        guard settings.autoOrganize, !working else { return }
        let folder = settings.organizeFolder
        let excluded = settings.organizeExcluded
        let since = settings.autoOrganizeSince
        let plan = await Task.detached { Self.plan(folder: folder, excluded: excluded, since: since) }.value
        if !plan.entries.isEmpty {
            await organize(plan.entries, in: folder, automatic: true)
        }
        // Downloads still arriving: look again in a moment.
        if plan.waiting > 0 { scheduleAutomatic(after: 6) }
    }

    // MARK: - Window

    /// Preview of sorting `folder`, with the choice of kinds, then the result and undo.
    func showWindow(for folder: URL? = nil) {
        let folder = folder ?? Settings.shared.organizeFolder
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 460, height: 420)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
            self.window = window
        }
        guard let window else { return }
        window.title = tr("Ordenar por tipo")
        let hosting = NSHostingController(rootView: OrganizeView(folder: folder))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 520, height: 560))
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeWindow() { window?.close() }

    /// Asks for a folder, then shows its preview.
    func chooseFolderAndShow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Settings.shared.organizeFolder
        panel.prompt = tr("Elegir")
        panel.message = tr("Elige la carpeta que quieres ordenar por tipo.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showWindow(for: url)
    }
}
