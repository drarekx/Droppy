import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar app: no Dock icon (Info.plist also sets LSUIElement).
    app.setActivationPolicy(.accessory)
    app.run()
}
