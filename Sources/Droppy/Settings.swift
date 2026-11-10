import AppKit

enum ShakeSensitivity: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return tr("Baja")
        case .medium: return tr("Media")
        case .high: return tr("Alta")
        }
    }

    /// Direction changes needed, within `window` seconds, each after at least `distance` points.
    var reversals: Int { self == .high ? 3 : self == .medium ? 4 : 5 }
    var distance: CGFloat { self == .high ? 18 : self == .medium ? 28 : 42 }
    var window: TimeInterval { self == .high ? 0.9 : self == .medium ? 0.75 : 0.65 }
}

/// Order of files in a shelf's list.
enum ShelfSort: String, CaseIterable, Identifiable {
    case added, name, size, kind
    var id: String { rawValue }

    var title: String {
        switch self {
        case .added: return tr("Orden de llegada")
        case .name: return tr("Nombre")
        case .size: return tr("Tamaño")
        case .kind: return tr("Tipo")
        }
    }
}

/// Screen side of the fixed shelf.
enum DockEdge: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? tr("Izquierda") : tr("Derecha") }
}

/// Where along the side the fixed shelf sits.
enum DockAlignment: String, CaseIterable, Identifiable {
    case top, center, bottom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return tr("Arriba")
        case .center: return tr("Centro")
        case .bottom: return tr("Abajo")
        }
    }
}

/// Key that, pressed while dragging, opens a shelf at the mouse.
enum TriggerModifier: String, CaseIterable, Identifiable {
    case none, control, option, shift
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return tr("Ninguna")
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        }
    }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .none: return nil
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        }
    }
}

/// User preferences, persisted in UserDefaults (`com.egluu.droppy`).
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Shake the mouse while dragging to open a shelf.
    @Published var shakeEnabled: Bool { didSet { defaults.set(shakeEnabled, forKey: "shakeEnabled") } }
    @Published var shakeSensitivity: ShakeSensitivity { didSet { defaults.set(shakeSensitivity.rawValue, forKey: "shakeSensitivity") } }
    @Published var triggerModifier: TriggerModifier { didSet { defaults.set(triggerModifier.rawValue, forKey: "triggerModifier") } }
    /// ⌃⌥D opens a new shelf at the mouse.
    @Published var hotKeyEnabled: Bool { didSet { defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled") } }
    /// Files dragged (or moved) out of a shelf leave it; otherwise only a move removes them.
    @Published var removeAfterDrag: Bool { didSet { defaults.set(removeAfterDrag, forKey: "removeAfterDrag") } }
    @Published var closeWhenEmpty: Bool { didSet { defaults.set(closeWhenEmpty, forKey: "closeWhenEmpty") } }
    /// Closed shelves with files are kept in "Recent shelves".
    @Published var keepRecent: Bool { didSet { defaults.set(keepRecent, forKey: "keepRecent") } }
    @Published var hasLaunched: Bool { didSet { defaults.set(hasLaunched, forKey: "hasLaunched") } }
    /// Fixed shelf on the left edge of the screen.
    @Published var dockEnabled: Bool { didSet { defaults.set(dockEnabled, forKey: "dockEnabled") } }
    @Published var dockEdge: DockEdge { didSet { defaults.set(dockEdge.rawValue, forKey: "dockEdge") } }
    @Published var dockAlignment: DockAlignment { didSet { defaults.set(dockAlignment.rawValue, forKey: "dockAlignment") } }
    /// Colour theme of every shelf.
    @Published var shelfTheme: ShelfTheme { didSet { defaults.set(shelfTheme.rawValue, forKey: "shelfTheme") } }
    @Published var sort: ShelfSort { didSet { defaults.set(sort.rawValue, forKey: "shelfSort") } }
    @Published var sortDescending: Bool { didSet { defaults.set(sortDescending, forKey: "sortDescending") } }
    /// List sections per kind of file (Images, PDFs…).
    @Published var groupByKind: Bool { didSet { defaults.set(groupByKind, forKey: "groupByKind") } }

    /// Folder sorted by kind ("Sort Downloads…" and automatic sorting). Downloads by default.
    @Published var organizeFolderPath: String { didSet { defaults.set(organizeFolderPath, forKey: "organizeFolderPath") } }
    var organizeFolder: URL { URL(fileURLWithPath: organizeFolderPath, isDirectory: true) }
    /// Kinds left where they are when sorting.
    @Published var organizeExcluded: Set<OrganizeCategory> {
        didSet { defaults.set(organizeExcluded.map(\.rawValue).sorted(), forKey: "organizeExcluded") }
    }
    /// Sort new files in `organizeFolder` as they arrive.
    @Published var autoOrganize: Bool { didSet { defaults.set(autoOrganize, forKey: "autoOrganize") } }
    /// Automatic sorting only touches files added after this (when it was turned on, or after an undo).
    var autoOrganizeSince: Date {
        get { defaults.object(forKey: "autoOrganizeSince") as? Date ?? Date() }
        set { defaults.set(newValue, forKey: "autoOrganizeSince") }
    }

    private init() {
        defaults.register(defaults: ["shakeEnabled": true, "hotKeyEnabled": true, "removeAfterDrag": true,
                                     "closeWhenEmpty": true, "keepRecent": true,
                                     "dockEnabled": true, "groupByKind": true])
        shakeEnabled = defaults.bool(forKey: "shakeEnabled")
        shakeSensitivity = ShakeSensitivity(rawValue: defaults.string(forKey: "shakeSensitivity") ?? "") ?? .medium
        triggerModifier = TriggerModifier(rawValue: defaults.string(forKey: "triggerModifier") ?? "") ?? .none
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        removeAfterDrag = defaults.bool(forKey: "removeAfterDrag")
        closeWhenEmpty = defaults.bool(forKey: "closeWhenEmpty")
        keepRecent = defaults.bool(forKey: "keepRecent")
        hasLaunched = defaults.bool(forKey: "hasLaunched")
        dockEnabled = defaults.bool(forKey: "dockEnabled")
        dockEdge = DockEdge(rawValue: defaults.string(forKey: "dockEdge") ?? "") ?? .left
        dockAlignment = DockAlignment(rawValue: defaults.string(forKey: "dockAlignment") ?? "") ?? .center
        shelfTheme = ShelfTheme(rawValue: defaults.string(forKey: "shelfTheme") ?? "") ?? .droppy
        sort = ShelfSort(rawValue: defaults.string(forKey: "shelfSort") ?? "") ?? .added
        sortDescending = defaults.bool(forKey: "sortDescending")
        groupByKind = defaults.bool(forKey: "groupByKind")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        organizeFolderPath = defaults.string(forKey: "organizeFolderPath") ?? downloads.path
        organizeExcluded = Set((defaults.stringArray(forKey: "organizeExcluded") ?? []).compactMap(OrganizeCategory.init(rawValue:)))
        autoOrganize = defaults.bool(forKey: "autoOrganize")
    }
}
