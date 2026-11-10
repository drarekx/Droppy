import AppKit
import UniformTypeIdentifiers

/// Turns pasteboard contents (drops, ⌘V, the Services menu) into files on a shelf.
/// Files are referenced where they are; promised files, images, text and links are
/// written to the shelf's clips folder first.
@MainActor
enum Importer {
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .png, .tiff, .pdf, .rtf]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Adds what `pasteboard` holds to `shelf`. Returns false when there was nothing usable.
    @discardableResult
    static func add(from pasteboard: NSPasteboard, to shelf: Shelf) -> Bool {
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            shelf.add(fileURLs)
            return true
        }

        // Files that don't exist yet (Mail attachments, Photos, some browsers).
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let folder = clipsFolder(for: shelf)
            shelf.busy = tr("Recibiendo archivos…")
            var pending = receivers.count
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                    MainActor.assumeIsolated {
                        if error == nil { shelf.add([url], clips: true) }
                        pending -= 1
                        if pending == 0 { shelf.busy = nil }
                    }
                }
            }
            return true
        }

        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           let scheme = url.scheme, ["http", "https"].contains(scheme) {
            return addClip(webloc(url), name: (url.host ?? "Link") + ".webloc", to: shelf)
        }

        if let image = NSImage(pasteboard: pasteboard), pasteboard.availableType(from: [.png, .tiff, .pdf]) != nil {
            let data = pasteboard.data(forType: .png) ?? png(image)
            if let data { return addClip(data, name: tr("Imagen %@", stamp()) + ".png", to: shelf) }
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return addClip(Data(text.utf8), name: textName(text) + ".txt", to: shelf)
        }
        return false
    }

    // MARK: - Clips

    private static func clipsFolder(for shelf: Shelf) -> URL {
        let folder = Shelves.clipsDirectory(for: shelf.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func addClip(_ data: Data, name: String, to shelf: Shelf) -> Bool {
        let url = FileOps.uniqueURL(in: clipsFolder(for: shelf), name: sanitize(name))
        do {
            try data.write(to: url, options: .atomic)
            shelf.add([url], clips: true)
            return true
        } catch {
            NSLog("Droppy: couldn't write clip: \(error)")
            return false
        }
    }

    private static func webloc(_ url: URL) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString],
                                             format: .xml, options: 0)) ?? Data()
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// "Texto" plus the first words of the text.
    private static func textName(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return tr("Texto %@", stamp()) }
        return String(trimmed.prefix(40))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
