import AppKit
import SwiftUI

/// Preview of sorting a folder by kind: what goes where, which kinds to move, then the result and undo.
struct OrganizeView: View {
    @State var folder: URL
    @ObservedObject private var organizer = Organizer.shared
    @ObservedObject private var settings = Settings.shared
    @State private var plan: OrganizePlan?
    @State private var excluded: Set<OrganizeCategory> = Settings.shared.organizeExcluded
    @State private var result: Outcome?

    private enum Outcome {
        case sorted(count: Int, failures: [String])
        case undone(count: Int, failures: [String])
    }

    private var selected: [OrganizePlan.Entry] {
        plan?.entries.filter { !excluded.contains($0.category) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let result {
                outcome(result)
            } else if let plan {
                if plan.entries.isEmpty {
                    empty
                } else {
                    categories(plan)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
        .task(id: folder) { await reload() }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Ordenar por tipo")).font(.system(size: 20, weight: .semibold))
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.accentText)
                Text(FileManager.default.displayName(atPath: folder.path)).fontWeight(.medium)
                Text(folder.path).monospacedText(size: 11).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(tr("Cambiar…"), action: chooseFolder)
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 26))
                    .disabled(organizer.working || result != nil)
            }
            Text(tr("Cada archivo va a una subcarpeta según su tipo (Imatges, PDF, Documents…). No se tocan las carpetas, los archivos ocultos ni las descargas a medias."))
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.ok)
            Text(tr("No hay nada que ordenar")).font(.system(size: 13, weight: .medium))
            Text(tr("Todos los archivos ya están en subcarpetas.")).font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func categories(_ plan: OrganizePlan) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(plan.categories) { category in
                    categoryRow(category, entries: plan.entries(in: category))
                }
            }
        }
    }

    private func categoryRow(_ category: OrganizeCategory, entries: [OrganizePlan.Entry]) -> some View {
        let on = !excluded.contains(category)
        return Button {
            if on { excluded.insert(category) } else { excluded.remove(category) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(on ? Theme.accentText : Theme.text3)
                Image(systemName: category.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("→ \(category.folderName)").fontWeight(.medium).foregroundStyle(on ? Theme.text : Theme.text3)
                        Spacer()
                        let size = Format.bytes(entries.reduce(0) { $0 + $1.size })
                        Text(entries.count == 1 ? tr("1 archivo · %@", size) : tr("%d archivos · %@", entries.count, size))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text2)
                    }
                    Text(sample(entries))
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(organizer.working)
    }

    private func sample(_ entries: [OrganizePlan.Entry]) -> String {
        let names = entries.prefix(4).map(\.url.lastPathComponent).joined(separator: ", ")
        return entries.count > 4 ? names + "…" : names
    }

    private func outcome(_ outcome: Outcome) -> some View {
        let (symbol, title, failures): (String, String, [String]) = {
            switch outcome {
            case let .sorted(count, failures): return ("checkmark.circle.fill", tr("%d archivos ordenados", count), failures)
            case let .undone(count, failures): return ("arrow.uturn.backward.circle.fill", tr("%d archivos devueltos a su sitio", count), failures)
            }
        }()
        return VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.ok)
            Text(title).font(.system(size: 14, weight: .semibold))
            if !failures.isEmpty {
                Text(tr("No se pudieron mover %d archivos:", failures.count) + "\n" + failures.prefix(6).joined(separator: "\n"))
                    .font(.system(size: 11)).foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            switch result {
            case .sorted?:
                Button(tr("Deshacer")) { Task { await undo() } }
                    .buttonStyle(.appSecondary)
                    .disabled(organizer.working || organizer.lastBatch == nil)
                Button(tr("Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .buttonStyle(.appSecondary)
                Spacer()
                Button(tr("Hecho")) { Organizer.shared.closeWindow() }
                    .buttonStyle(.appPrimary)
                    .keyboardShortcut(.defaultAction)
            case .undone?:
                Spacer()
                Button(tr("Hecho")) { Organizer.shared.closeWindow() }
                    .buttonStyle(.appPrimary)
                    .keyboardShortcut(.defaultAction)
            case nil:
                if organizer.working { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("Cancelar")) { Organizer.shared.closeWindow() }
                    .buttonStyle(.appSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(tr("Ordenar %d archivos", selected.count)) { Task { await sort() } }
                    .buttonStyle(.appPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || organizer.working)
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        plan = nil
        let folder = folder
        // Show every kind here; the excluded ones appear unticked.
        plan = await Task.detached { Organizer.plan(folder: folder, excluded: []) }.value
    }

    private func sort() async {
        // Remember the choice: automatic sorting uses it too.
        settings.organizeExcluded = excluded
        let (batch, failures) = await organizer.organize(selected, in: folder)
        result = .sorted(count: batch.moves.count, failures: failures)
    }

    private func undo() async {
        let (count, failures) = await organizer.undoLast()
        result = .undone(count: count, failures: failures)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = tr("Elegir")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
    }
}
