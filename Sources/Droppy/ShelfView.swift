import AppKit
import SwiftUI

/// Content of a shelf window: header, the files (stacked or as a list) and a footer.
struct ShelfView: View {
    @ObservedObject var shelf: Shelf

    @ObservedObject private var settings = Settings.shared

    var body: some View {
        if shelf.isDocked {
            let left = settings.dockEdge == .left
            ZStack(alignment: left ? .leading : .trailing) {
                if shelf.contentShown {
                    content.transition(.move(edge: left ? .leading : .trailing))
                } else if !shelf.revealed {
                    DockTab(shelf: shelf)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }

    /// Docked: square on the screen edge, rounded on the other side.
    private var shape: some InsettableShape {
        dockShape(docked: shelf.isDocked, radius: shelf.isDocked ? 14 : 16)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ShelfHeader(shelf: shelf)
            ZStack {
                if shelf.items.isEmpty {
                    EmptyShelf(targeted: shelf.isTargeted, docked: shelf.isDocked)
                } else if shelf.expanded {
                    ShelfList(shelf: shelf)
                } else {
                    ShelfStack(shelf: shelf)
                }
                if let busy = shelf.busy {
                    BusyOverlay(text: busy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !shelf.items.isEmpty {
                ShelfFooter(shelf: shelf)
            }
        }
        .background(ShelfBackground())
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(shelf.isTargeted ? Theme.accent : Color.white.opacity(0.10),
                              lineWidth: shelf.isTargeted ? 2 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: shelf.isTargeted)
        .animation(.easeOut(duration: 0.18), value: shelf.items.count)
    }
}

/// What happens to files dragged out of a shelf.
@MainActor
func shelfDragEnded(_ shelf: Shelf, urls: [URL], operation: NSDragOperation) {
    guard !operation.isEmpty else { return }
    // The docked shelf keeps its files until you remove them (it follows them if they move).
    if shelf.isDocked {
        if operation.contains(.delete) { shelf.remove(urls: urls) } else { shelf.refresh() }
        return
    }
    if operation.contains(.delete) || operation == .move || Settings.shared.removeAfterDrag {
        shelf.remove(urls: urls)
    } else {
        shelf.refresh()
    }
}

// MARK: - Parts

private struct ShelfBackground: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            Theme.window.opacity(0.55)
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct ShelfHeader: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        HStack(spacing: 6) {
            Button {
                Shelves.shared.close(shelf)
            } label: {
                Image(systemName: shelf.isDocked ? "chevron.left" : "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help(shelf.isDocked ? tr("Plegar (Esc)") : tr("Cerrar bandeja (Esc)"))

            Spacer(minLength: 0)
            if shelf.isDocked {
                Label(tr("Bandeja fija"), systemImage: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
            }
            Menu {
                ShelfMenuContent(shelf: shelf)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 22, height: 18)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("Acciones"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(WindowDragHandle())
    }
}

/// Dragging here moves the window (the rest of the shelf drags files).
private struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {}
}

private struct EmptyShelf: View {
    let targeted: Bool
    var docked = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(targeted ? Theme.accentText : Theme.text3)
            Text(targeted ? tr("Suelta para guardar") : tr("Suelta archivos aquí"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(targeted ? Theme.text : Theme.text2)
            Text(docked ? tr("Lo que dejes aquí se queda hasta que lo quites.")
                        : tr("Esperarán aquí hasta que los arrastres a su destino."))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragHandle())
    }
}

/// Collapsed shelf: a pile of the first files. Dragging it takes every file.
private struct ShelfStack: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        let shown = Array(shelf.items.prefix(3))
        VStack(spacing: 8) {
            ZStack {
                ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { index, item in
                    FileThumbnail(url: item.url, size: 84)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                        .rotationEffect(.degrees(shown.count == 1 ? 0 : Double(index - 1) * 9))
                        .offset(x: shown.count == 1 ? 0 : CGFloat(index - 1) * 12)
                }
                if shelf.items.count > 1 {
                    Text("\(shelf.items.count)")
                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Theme.accentFill, in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.white.opacity(0.25)) }
                        .offset(x: 46, y: -40)
                }
            }
            .frame(height: 110)

            VStack(spacing: 2) {
                Text(shelf.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(shelf.items.count == 1 ? FileInfo.detail(of: shelf.items[0].url) : Format.bytes(shelf.totalBytes))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            FileDragArea(
                urls: { shelf.urls },
                onClick: { _ in if shelf.items.count > 1 { shelf.expanded = true } },
                onDoubleClick: { if shelf.items.count == 1 { ShelfAction.open.perform(on: shelf.items, in: shelf) } },
                onDragEnded: { urls, operation in shelfDragEnded(shelf, urls: urls, operation: operation) },
                menu: { ShelfAction.menu(for: shelf.items, in: shelf) })
        }
        .help(tr("Arrastra para llevarte todos los archivos · clic para verlos uno a uno"))
    }
}

/// Expanded shelf: one row per file; each row (or the selection) can be dragged on its own.
private struct ShelfList: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if settings.groupByKind {
                    ForEach(shelf.grouped(), id: \.category) { group in
                        HStack(spacing: 6) {
                            Image(systemName: group.category.symbol)
                            Text(group.category.title.uppercased())
                                .tracking(0.5)
                            Text("\(group.items.count)").foregroundStyle(Theme.text3.opacity(0.7))
                            Spacer()
                            let bytes = group.items.reduce(0) { $0 + FileInfo.size(of: $1.url) }
                            if bytes > 0 { Text(Format.bytes(bytes)) }
                        }
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        ForEach(group.items) { item in
                            ShelfRow(shelf: shelf, item: item, selected: shelf.selection.contains(item.id))
                        }
                    }
                } else {
                    ForEach(shelf.sorted()) { item in
                        ShelfRow(shelf: shelf, item: item, selected: shelf.selection.contains(item.id))
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.automatic)
    }
}

private struct ShelfRow: View {
    @ObservedObject var shelf: Shelf
    let item: ShelfItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FileThumbnail(url: item.url, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(FileInfo.detail(of: item.url))
                    .font(.system(size: 10.5)).monospacedDigit()
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
            if hovering {
                Button {
                    shelf.remove([item.id])
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .help(tr("Quitar de la bandeja"))
                .zIndex(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Theme.navSelected : (hovering ? Color.white.opacity(0.05) : .clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            // Leaves room for the remove button on the right.
            HStack(spacing: 0) {
                FileDragArea(
                    urls: { shelf.targets(for: item).map(\.url) },
                    onClick: { modifiers in shelf.click(item, modifiers: modifiers) },
                    onDoubleClick: { ShelfAction.open.perform(on: [item], in: shelf) },
                    onDragEnded: { urls, operation in shelfDragEnded(shelf, urls: urls, operation: operation) },
                    menu: { ShelfAction.menu(for: shelf.targets(for: item), in: shelf) })
                Color.clear.frame(width: hovering ? 30 : 0)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct ShelfFooter: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        HStack(spacing: 6) {
            if !shelf.isDocked, shelf.items.count > 1 || shelf.expanded {
                Button {
                    shelf.expanded.toggle()
                    if !shelf.expanded { shelf.selection = [] }
                } label: {
                    Label(shelf.expanded ? tr("Agrupar") : tr("Ver todos"),
                          systemImage: shelf.expanded ? "square.stack" : "list.bullet")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 24))
            }
            if shelf.expanded {
                SortMenu()
            }
            Spacer(minLength: 0)
            footerButton(.share)
            footerButton(.reveal)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private func footerButton(_ action: ShelfAction) -> some View {
        Button {
            action.perform(on: shelf.actionTargets, in: shelf)
        } label: {
            Image(systemName: action.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 28, height: 24)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.radius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.title)
    }
}

/// Order and grouping of the list (shared by every shelf).
private struct SortMenu: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Menu {
            Picker(tr("Ordenar por"), selection: $settings.sort) {
                ForEach(ShelfSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(tr("Descendente"), isOn: $settings.sortDescending)
            Toggle(tr("Agrupar por tipo"), isOn: $settings.groupByKind)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 28, height: 24)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.radius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("Ordenar y agrupar"))
    }
}

/// Docked shelf folded on the screen edge: a thin tab with the file count.
/// Fixed shelf folded on the screen edge: a thin, quiet strip; a dot shows it holds files.
private struct DockTab: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        ZStack {
            (shelf.isTargeted ? Theme.accentFill : Color.white.opacity(0.22))
            if !shelf.items.isEmpty && !shelf.isTargeted {
                Circle().fill(Theme.accentText).frame(width: 4, height: 4)
            }
        }
        .overlay { dockShape(docked: true, radius: 4).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5) }
        .help(tr("Bandeja fija: pasa el ratón o arrastra archivos hasta aquí"))
    }
}

/// Rounded on the side away from the screen edge when docked; all round otherwise.
@MainActor
func dockShape(docked: Bool, radius: CGFloat) -> UnevenRoundedRectangle {
    guard docked else { return UnevenRoundedRectangle(cornerRadii: .init(topLeading: radius, bottomLeading: radius,
                                                                       bottomTrailing: radius, topTrailing: radius),
                                                      style: .continuous) }
    let left = Settings.shared.dockEdge == .left
    return UnevenRoundedRectangle(topLeadingRadius: left ? 0 : radius, bottomLeadingRadius: left ? 0 : radius,
                                  bottomTrailingRadius: left ? radius : 0, topTrailingRadius: left ? radius : 0,
                                  style: .continuous)
}

private struct BusyOverlay: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window.opacity(0.75))
    }
}
