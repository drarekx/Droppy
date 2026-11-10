import AppKit
import ServiceManagement
import SwiftUI

struct SettingsPane: View {
    @ObservedObject private var localizer = Localizer.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var settings = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(tr("Ajustes")).font(.system(size: 22, weight: .semibold))
                    .padding(.top, 16)

                HowItWorksCard()

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(tr("Abrir una bandeja"))
                    SwitchRow(title: tr("Agitar el ratón al arrastrar"),
                              detail: tr("Mientras arrastras archivos, mueve el ratón a izquierda y derecha varias veces."),
                              isOn: $settings.shakeEnabled)
                    HStack {
                        Text(tr("Sensibilidad")).foregroundStyle(settings.shakeEnabled ? Theme.text : Theme.text3)
                        Spacer()
                        SegmentedControl(options: ShakeSensitivity.allCases.map { ($0.title, $0) },
                                         selection: $settings.shakeSensitivity)
                            .disabled(!settings.shakeEnabled)
                    }
                    .padding(.bottom, 6)
                    Divider().overlay(Theme.line)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("Tecla al arrastrar"))
                            Text(tr("Púlsala mientras arrastras para abrir la bandeja sin agitar."))
                                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        SegmentedControl(options: TriggerModifier.allCases.map { ($0.title, $0) },
                                         selection: $settings.triggerModifier)
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(Theme.line)
                    SwitchRow(title: tr("Atajo de teclado %@", HotKey.display),
                              detail: tr("Abre una bandeja vacía donde esté el ratón, desde cualquier app."),
                              isOn: $settings.hotKeyEnabled)
                    Text(tr("También: suelta archivos en el icono de la barra de menús, usa «Abrir con» → %@ o el menú Servicios → «Add to Droppy».", AppInfo.name))
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .appCard()

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(tr("Bandeja fija"))
                    SwitchRow(title: tr("Bandeja fija en el borde izquierdo"),
                              detail: tr("Una pestaña en el borde izquierdo de la pantalla. Se abre al pasar el ratón o al arrastrar archivos hasta el borde, y lo que dejes se queda hasta que lo quites."),
                              isOn: $settings.dockEnabled)
                    Divider().overlay(Theme.line)
                    HStack {
                        Text(tr("Ordenar por"))
                        Spacer()
                        SegmentedControl(options: ShelfSort.allCases.map { ($0.title, $0) }, selection: $settings.sort)
                    }
                    .padding(.vertical, 6)
                    SwitchRow(title: tr("Descendente"), isOn: $settings.sortDescending)
                    SwitchRow(title: tr("Agrupar por tipo"),
                              detail: tr("En la lista, separa imágenes, PDF, documentos, vídeos… con lo que ocupa cada grupo."),
                              isOn: $settings.groupByKind)
                }
                .appCard()

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(tr("Bandejas"))
                    SwitchRow(title: tr("Quitar los archivos al sacarlos de la bandeja"),
                              detail: tr("Al arrastrarlos a otro sitio dejan la bandeja. Si lo desactivas, solo la dejan los que se mueven."),
                              isOn: $settings.removeAfterDrag)
                    SwitchRow(title: tr("Cerrar la bandeja cuando se vacía"), isOn: $settings.closeWhenEmpty)
                    SwitchRow(title: tr("Guardar las bandejas cerradas en «Recientes»"),
                              detail: tr("Desde el icono de la barra de menús se pueden volver a abrir."),
                              isOn: $settings.keepRecent)
                    SwitchRow(title: tr("Abrir al iniciar sesión"),
                              isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    if let loginError {
                        Label(loginError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .appCard()

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(tr("Idioma"))
                    SegmentedControl(options: AppLanguage.allCases.map { ($0.nativeName, $0) },
                                     selection: $localizer.choice)
                }
                .appCard()

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(tr("Actualizaciones"))
                    SwitchRow(title: tr("Buscar actualizaciones automáticamente"),
                              detail: tr("Al abrir la app y una vez al día, desde GitHub (%@).", AppInfo.repo),
                              isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                    HStack {
                        Text(tr("Versión %@", Updater.currentVersion)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button(updater.state == .idle ? tr("Buscar ahora") : tr("Buscando…")) {
                            Task { await updater.check(userInitiated: true) }
                        }
                        .buttonStyle(.appSecondary)
                        .disabled(updater.state != .idle)
                    }
                }
                .appCard()

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(tr("Datos"))
                    Text(tr("Las bandejas solo guardan dónde están tus archivos; no los copian. Lo que sueltas sin ser un archivo (texto, imágenes, enlaces) se guarda aquí:"))
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(Shelves.supportDirectory.path).monospacedText(size: 11).foregroundStyle(Theme.text3)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(tr("Mostrar en Finder")) {
                            try? FileManager.default.createDirectory(at: Shelves.supportDirectory, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([Shelves.supportDirectory])
                        }
                        .buttonStyle(.appSecondary)
                    }
                }
                .appCard()
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = tr("No se pudo cambiar: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The three steps, with a button to try it.
private struct HowItWorksCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(tr("Cómo funciona"))
            step(1, "hand.draw", tr("Empieza a arrastrar archivos y agita el ratón: aparece una bandeja."))
            step(2, "tray.and.arrow.down", tr("Suéltalos en la bandeja. Esperan ahí mientras cambias de carpeta, de app o de escritorio."))
            step(3, "arrow.up.right.square", tr("Arrástralos desde la bandeja a su destino, todos a la vez o uno a uno."))
            HStack {
                Text(tr("El icono de bandeja de la barra de menús tiene el resto."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                Spacer()
                Button(tr("Probar ahora")) { Shelves.shared.newShelf() }
                    .buttonStyle(.appPrimary)
            }
        }
        .appCard()
    }

    private func step(_ number: Int, _ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accentText)
                .frame(width: 30, height: 30)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            Text(text).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }
}
