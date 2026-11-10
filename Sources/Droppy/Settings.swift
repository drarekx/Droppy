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

/// Key that, pressed while dragging, opens a shelf at the mouse.
enum TriggerModifier: String, CaseIterable, Identifiable {
    case none, control, option, shift
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return tr("Ninguna")
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .shift: return "⇧ Shift"
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
    @Published var sort: ShelfSort { didSet { defaults.set(sort.rawValue, forKey: "shelfSort") } }
    @Published var sortDescending: Bool { didSet { defaults.set(sortDescending, forKey: "sortDescending") } }
    /// List sections per kind of file (Images, PDFs…).
    @Published var groupByKind: Bool { didSet { defaults.set(groupByKind, forKey: "groupByKind") } }

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
        sort = ShelfSort(rawValue: defaults.string(forKey: "shelfSort") ?? "") ?? .added
        sortDescending = defaults.bool(forKey: "sortDescending")
        groupByKind = defaults.bool(forKey: "groupByKind")
    }
}
