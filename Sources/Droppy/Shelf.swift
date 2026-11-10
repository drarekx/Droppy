import AppKit
import Combine
import UniformTypeIdentifiers

/// A file waiting on a shelf. The shelf only references it: the file stays where it is
/// until it is dragged out or moved. The bookmark follows the file if it is moved elsewhere.
struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    var url: URL
    var bookmark: Data?
    /// Created by Droppy from dropped text, images or links; lives in the shelf's clips folder.
    var isClip: Bool

    init(url: URL, isClip: Bool = false) {
        id = UUID()
        self.url = url
        self.isClip = isClip
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Same item at a new path (after Droppy moved it).
    func relocated(to url: URL) -> ShelfItem {
        var copy = self
        copy.url = url
        copy.isClip = false
        copy.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return copy
    }

    var name: String { FileManager.default.displayName(atPath: url.path) }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Where the file is now: its path if it still exists, else wherever the bookmark points.
    func resolved() -> ShelfItem? {
        if exists { return self }
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path),
              !url.path.contains("/.Trash/") else { return nil }
        var copy = self
        copy.url = url
        if stale { copy.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        return copy
    }
}

/// A floating "waiting list" of files.
@MainActor
final class Shelf: ObservableObject, Identifiable {
    let id: UUID
    let created: Date
    /// The fixed shelf on the left edge of the screen: keeps its files until you remove them.
    let isDocked: Bool
    @Published var items: [ShelfItem]
    /// Name given by the user. A named shelf is kept even when empty and doesn't close by itself.
    @Published var name: String?
    /// The name field in the header is open.
    @Published var editingName = false
    @Published var selection: Set<UUID> = []
    /// List of every file instead of the stacked preview.
    @Published var expanded = false
    /// A drag is hovering over the shelf.
    @Published var isTargeted = false
    /// Running a file operation (zip, copy, move…).
    @Published var busy: String?
    /// Docked shelf only: open (true) or folded into a tab at the screen edge.
    @Published var revealed = false
    /// Docked shelf only: the open shelf is on screen (slides in after the window grows, out before it shrinks).
    @Published var contentShown = false
    weak var panel: ShelfPanel?

    init(id: UUID = UUID(), created: Date = Date(), items: [ShelfItem] = [], docked: Bool = false, name: String? = nil) {
        self.id = id
        self.created = created
        self.items = items
        self.name = name
        isDocked = docked
        expanded = docked
    }

    /// Items in the order chosen in the shelf's sort menu.
    func sorted() -> [ShelfItem] {
        let settings = Settings.shared
        var result: [ShelfItem]
        switch settings.sort {
        case .added:
            result = items
        case .name:
            result = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            let sizes = Dictionary(items.map { ($0.id, FileInfo.size(of: $0.url)) }, uniquingKeysWith: { a, _ in a })
            result = items.sorted { sizes[$0.id, default: 0] < sizes[$1.id, default: 0] }
        case .kind:
            result = items.sorted {
                let a = FileCategory(url: $0.url), b = FileCategory(url: $1.url)
                return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
            }
        }
        return settings.sortDescending ? result.reversed() : result
    }

    /// Sorted items split by kind of file, in a fixed order (folders, images, PDFs…).
    func grouped() -> [(category: FileCategory, items: [ShelfItem])] {
        let sorted = sorted()
        let byCategory = Dictionary(grouping: sorted) { FileCategory(url: $0.url) }
        return FileCategory.allCases.compactMap { category in
            byCategory[category].map { (category, $0) }
        }
    }

    var urls: [URL] { items.map(\.url) }

    var title: String {
        switch items.count {
        case 0: return tr("Bandeja vacía")
        case 1: return items[0].name
        default: return tr("%d archivos", items.count)
        }
    }

    var isNamed: Bool { !(name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// Opens the name field; the window has to be key to type in it.
    func startRenaming() {
        guard !isDocked else { return }
        panel?.makeKey()
        editingName = true
    }

    /// The user's name, or a description of the files.
    var displayName: String { isNamed ? name! : title }

    var totalBytes: Int64 { items.reduce(0) { $0 + FileInfo.size(of: $1.url) } }

    /// Adds files not already on the shelf. Returns how many were added.
    @discardableResult
    func add(_ urls: [URL], clips: Bool = false) -> Int {
        let known = Set(items.map { $0.url.standardizedFileURL.path })
        var seen = Set<String>()
        let new = urls.filter {
            let path = $0.standardizedFileURL.path
            return !known.contains(path) && seen.insert(path).inserted
        }
        items += new.map { ShelfItem(url: $0, isClip: clips) }
        return new.count
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func remove(urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        remove(Set(items.filter { paths.contains($0.url.standardizedFileURL.path) }.map(\.id)))
    }

    /// Follows moved files and drops the ones that no longer exist.
    func refresh() {
        let updated = items.compactMap { $0.resolved() }
        if updated != items { items = updated }
        selection.formIntersection(items.map(\.id))
    }

    /// What an action applies to: the selection in list mode, otherwise everything.
    var actionTargets: [ShelfItem] {
        let selected = items.filter { selection.contains($0.id) }
        return expanded && !selected.isEmpty ? selected : items
    }

    /// What a right-click or drag on `item` applies to: the selection if it includes the item.
    func targets(for item: ShelfItem) -> [ShelfItem] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    /// Click in the list: plain click selects one, ⌘ toggles, ⇧ extends.
    func click(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if modifiers.contains(.shift) {
            // Range in the order shown (sorted, and grouped by kind if on).
            let shown = Settings.shared.groupByKind ? grouped().flatMap(\.items) : sorted()
            guard let anchor = shown.firstIndex(where: { selection.contains($0.id) }),
                  let index = shown.firstIndex(of: item) else { selection = [item.id]; return }
            selection = Set(shown[min(anchor, index)...max(anchor, index)].map(\.id))
        } else {
            selection = [item.id]
        }
    }
}

/// File sizes and kinds for display.
enum FileInfo {
    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        if values?.isDirectory == true { return 0 }
        return Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            && (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    static func kind(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? ""
    }

    static func detail(of url: URL) -> String {
        if isFolder(url) { return tr("Carpeta") }
        return Format.bytes(size(of: url))
    }
}

/// Kind of file, for grouping and sorting shelves.
enum FileCategory: Int, CaseIterable, Comparable, Identifiable {
    case folder, image, pdf, document, spreadsheet, presentation, video, audio, archive, code, app, other
    var id: Int { rawValue }

    static func < (a: FileCategory, b: FileCategory) -> Bool { a.rawValue < b.rawValue }

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        guard let type = values?.contentType else {
            self = values?.isDirectory == true ? .folder : .other
            return
        }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { self = .app }
        else if values?.isDirectory == true && values?.isPackage != true { self = .folder }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .spreadsheet) { self = .spreadsheet }
        else if type.conforms(to: .presentation) { self = .presentation }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .archive) || type.conforms(to: .diskImage) { self = .archive }
        else if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
                    || type.conforms(to: .xml) || type.conforms(to: .yaml) { self = .code }
        else if type.conforms(to: .text) || type.conforms(to: .compositeContent) || type.conforms(to: .rtf)
                    || type.identifier.hasPrefix("org.openxmlformats.wordprocessingml")
                    || type.identifier == "com.microsoft.word.doc" || type.identifier == "com.apple.iwork.pages.sffpages"
                    || type.conforms(to: .epub) { self = .document }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .folder: return tr("Carpetas")
        case .image: return tr("Imágenes")
        case .pdf: return "PDF"
        case .document: return tr("Documentos")
        case .spreadsheet: return tr("Hojas de cálculo")
        case .presentation: return tr("Presentaciones")
        case .video: return tr("Vídeos")
        case .audio: return tr("Audio")
        case .archive: return tr("Comprimidos e imágenes de disco")
        case .code: return tr("Código")
        case .app: return tr("Apps")
        case .other: return tr("Otros")
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .video: return "film"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .app: return "app"
        case .other: return "doc"
        }
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
