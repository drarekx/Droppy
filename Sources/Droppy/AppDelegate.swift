import AppKit
import Combine
import SwiftUI

/// App identity shared by the updater, menus and storage.
enum AppInfo {
    static let name = "Droppy"
    /// GitHub repository the updater and installer read releases from.
    static let repo = "drarekx/Droppy"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pendingOpen: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        Localizer.shared.$choice
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setupMainMenu() }
            .store(in: &cancellables)

        Shelves.shared.load()
        DragMonitor.shared.start()
        HotKey.shared.action = { Shelves.shared.newShelf() }
        HotKey.shared.setEnabled(Settings.shared.hotKeyEnabled)
        Settings.shared.$hotKeyEnabled
            .dropFirst()
            .sink { HotKey.shared.setEnabled($0) }
            .store(in: &cancellables)
        Settings.shared.$dockEnabled
            .dropFirst()
            .sink { Shelves.shared.setDockVisible($0) }
            .store(in: &cancellables)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        Updater.shared.start()

        if !Settings.shared.hasLaunched {
            Settings.shared.hasLaunched = true
            showSettings()
        }
        launched = true
        if !pendingOpen.isEmpty {
            Shelves.shared.newShelf(with: pendingOpen)
            pendingOpen = []
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Shelves.shared.save()
    }

    /// Opening the app again (Finder, Spotlight) shows Settings, since there's no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// "Open with Droppy" or files dropped on the app's icon: a new shelf with them.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Finder may deliver one call per file: gather them into a single shelf.
        let flush = pendingOpen.isEmpty
        pendingOpen += urls
        guard launched, flush else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.pendingOpen.isEmpty else { return }
            Shelves.shared.newShelf(with: self.pendingOpen)
            self.pendingOpen = []
        }
    }

    // MARK: - Services menu ("Add to Droppy")

    @objc func addToDroppy(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        Shelves.shared.newShelf(from: pasteboard)
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: AppInfo.name)
            button.image?.isTemplate = true
            // Dropping files on the icon puts them on a new shelf below it.
            let drop = StatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            button.addSubview(drop)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time it opens, so recent shelves and language are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shelves = Shelves.shared

        let new = ClosureMenuItem(title: tr("Nueva bandeja")) { shelves.newShelf(at: Self.belowStatusItem()) }
        new.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil)
        menu.addItem(new)
        let paste = ClosureMenuItem(title: tr("Nueva bandeja con lo copiado")) {
            shelves.newShelf(from: .general, at: Self.belowStatusItem())
        }
        paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(paste)

        if Settings.shared.dockEnabled {
            let dock = ClosureMenuItem(title: tr("Abrir la bandeja fija")) { shelves.revealDock() }
            dock.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
            menu.addItem(dock)
        }

        if !shelves.open.isEmpty {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: tr("Traer bandejas al frente")) { shelves.bringAllToFront() })
            menu.addItem(ClosureMenuItem(title: tr("Cerrar todas las bandejas")) { shelves.closeAll() })
        }

        let recentItem = NSMenuItem(title: tr("Bandejas recientes"), action: nil, keyEquivalent: "")
        recentItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let recentMenu = NSMenu()
        if shelves.recent.isEmpty {
            let empty = NSMenuItem(title: tr("Ninguna"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Localizer.shared.locale
            formatter.unitsStyle = .short
            for shelf in shelves.recent {
                let title = "\(shelf.title) · \(formatter.localizedString(for: shelf.created, relativeTo: Date()))"
                let entry = ClosureMenuItem(title: title) { shelves.reopen(shelf) }
                if let first = shelf.items.first {
                    let icon = NSWorkspace.shared.icon(forFile: first.url.path)
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                }
                recentMenu.addItem(entry)
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(ClosureMenuItem(title: tr("Borrar recientes")) { shelves.clearRecent() })
        }
        recentItem.submenu = recentMenu
        menu.addItem(.separator())
        menu.addItem(recentItem)

        menu.addItem(.separator())
        let hint = NSMenuItem(title: tr("Agita el ratón al arrastrar archivos · %@", HotKey.display), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: tr("Ajustes…"), keyEquivalent: ",") { [weak self] in self?.showSettings() })
        let update = ClosureMenuItem(title: tr("Buscar actualizaciones…")) {
            Task { await Updater.shared.check(userInitiated: true) }
        }
        update.isEnabled = Updater.shared.state == .idle
        menu.addItem(update)
        menu.addItem(ClosureMenuItem(title: tr("Acerca de %@", AppInfo.name)) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: tr("Salir de %@", AppInfo.name), keyEquivalent: "q") { NSApp.terminate(nil) })
    }

    /// Centre point for a shelf opened from the menu bar icon: just below it.
    static func belowStatusItem() -> NSPoint? {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let window = delegate.statusItem?.button?.window else { return nil }
        let frame = window.frame
        return NSPoint(x: frame.midX, y: frame.minY - ShelfPanel.collapsedSize.height / 2 - 8)
    }

    // MARK: - Settings window

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = tr("Ajustes de %@", AppInfo.name)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 520, height: 480)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
            let hosting = NSHostingController(rootView: SettingsPane())
            // NSHostingController would otherwise shrink the window to its ideal size.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 620, height: 720))
            window.center()
            window.setFrameAutosaveName("SettingsWindow")
            settingsWindow = window
        }
        settingsWindow?.title = tr("Ajustes de %@", AppInfo.name)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Main menu (not visible: the app has no menu bar, but it gives shelves ⌘C, ⌘V, ⌘W…)

    private func setupMainMenu() {
        let main = NSMenu()
        let name = AppInfo.name

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Acerca de %@", name),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Ajustes…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Salir de %@", name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Edición"))
        edit.addItem(withTitle: tr("Deshacer"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Rehacer"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Cortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Pegar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let trash = edit.addItem(withTitle: tr("Mover a la papelera"), action: #selector(ShelfPanel.deleteSelection(_:)), keyEquivalent: "\u{8}")
        trash.keyEquivalentModifierMask = [.command]
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: tr("Ventana"))
        window.addItem(withTitle: tr("Cerrar ventana"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: tr("Minimizar"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}

/// Drop target laid over the menu bar icon.
final class StatusDropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(MainActor.assumeIsolated { Importer.acceptedTypes })
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks go to the status button underneath (it opens the menu).
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (superview as? NSButton)?.highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        (superview as? NSButton)?.highlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (superview as? NSButton)?.highlight(false)
        MainActor.assumeIsolated {
            Shelves.shared.newShelf(from: sender.draggingPasteboard, at: AppDelegate.belowStatusItem())
        }
        return true
    }
}
