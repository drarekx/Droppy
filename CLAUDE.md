# Droppy

App de barra de menús de macOS (sin Dock, `LSUIElement`) con bandejas flotantes donde dejar archivos mientras se arrastran y sacarlos después, como Dropover. Swift + AppKit/SwiftUI, sin dependencias. Repo previsto: https://github.com/drarekx/Droppy (constante `AppInfo.repo` en `AppDelegate.swift`, también en `install.sh` y README).

Estructura, instalador, actualizador, tema y traducciones heredados de DemoImages (https://github.com/drarekx/DemoImages), que los heredó de Wallpy. El comportamiento replica Dropover 5.2.5 (`me.damir.dropover-mac`), analizado con REA y su `Info.plist`: app `LSUIElement`, bandeja al agitar el ratón (`ShakeGestureSensitivity`) o con tecla modificadora (`ShelfTriggerModifierKeyEnabled`), acciones (`CopyToPasteboardAction`, `CompressAction`, `QuickLookAction`, `RevealInFinderAction`, `SharingServiceAction`, `MoveToNewShelfAction`, `ClearShelfAction`, `AddFromClipboardAction`), bandejas recientes y servicio «Add to Dropover». No se ha copiado código ni recursos.

## Compilar y ejecutar

```sh
swift build                      # debug, comprobación rápida
./build-app.sh                   # release → build/Droppy.app + build/Droppy.zip (universal con Xcode; nativo con solo CLT)
VERSION=1.2.0 ./build-app.sh     # versión en Info.plist (por defecto 1.0.0)
open build/Droppy.app
open -a "$PWD/build/Droppy.app" a.txt b.png   # abrir archivos = bandeja nueva con ellos
```

- Requisitos: macOS 14+. `Package.swift` usa tools 5.10 (modo Swift 5).
- No hay tests. Verificar compilando y lanzando la app.
- La copia de `build/` tiene versión 1.0.0, así que su actualizador siempre ve versiones nuevas.

## Publicar una versión

```sh
git tag v1.0.1 && git push origin v1.0.1
```

`.github/workflows/release.yml` (macos-15) compila con `VERSION` = tag y crea el release con `Droppy.zip` y `Droppy.zip.sha256`. `Updater.swift` consulta `releases/latest`, verifica el SHA-256 y el `Info.plist` y cambia el bundle. `build.yml` compila arm64 + x86_64 y verifica que `en` y `ca` tienen las mismas claves y que todo `tr()` está traducido. La app no está notarizada (firma ad-hoc).

## Estructura (`Sources/Droppy/`)

| Archivo | Qué hace |
|---|---|
| `main.swift`, `AppDelegate.swift` | Arranque (`.accessory`), `AppInfo`, icono y menú de la barra de menús (reconstruido en `menuNeedsUpdate`), `StatusDropView` (soltar sobre el icono), ventana de Ajustes, menú principal invisible (da ⌘C/⌘V/⌘W a las bandejas), servicio `addToDroppy`, abrir archivos |
| `Shelf.swift` | `ShelfItem` (URL + bookmark que sigue al archivo), `Shelf` (archivos, selección, modo lista, `isDocked`/`revealed`, `sorted()`/`grouped()`), `FileCategory` (tipo por `UTType`), `FileInfo`, `Format` |
| `Shelves.swift` | Bandejas abiertas y recientes, bandeja fija (`docked`, `setDockVisible`, `revealDock`), sus ventanas, `shelves.json`, carpeta de clips, refresco cada 3 s |
| `ShelfPanel.swift` | `ShelfPanel` (NSPanel sin borde, no activante, flotante, en todos los escritorios), teclado, Quick Look; `ShelfDropView` (destino de arrastre de la bandeja) |
| `ShelfView.swift` | Vista SwiftUI: cabecera (mover ventana, cerrar, «…»), montón, lista, pie; `shelfDragEnded` (qué pasa al sacar archivos) |
| `FileDragArea.swift` | Capa AppKit que arrastra varios archivos a la vez (`NSDraggingSource`) y da clic, doble clic y menú contextual |
| `ShelfActions.swift` | `ShelfAction` (menús «…» y contextual), `FileOps` (copiar/mover a carpeta, ZIP con `ditto`) |
| `Organizer.swift` | Ordenar carpetas por tipo: `OrganizeCategory` (nombres de carpeta siempre en catalán), `plan` (qué se movería), `perform`, deshacer con `organize-history.json`, vigilancia automática de la carpeta (`DispatchSource` sobre el directorio) |
| `OrganizeView.swift` | Ventana de vista previa: tipos con casilla, recuento y tamaño, ordenar, deshacer |
| `Importer.swift` | Portapapeles/arrastre → archivos: URLs, archivos prometidos, enlaces (`.webloc`), imágenes (`.png`), texto (`.txt`) |
| `DragMonitor.swift` | Monitor global del ratón: detecta arrastres con contenido y el gesto de agitar o la tecla |
| `HotKey.swift` | Atajo global ⌃⌥D con Carbon `RegisterEventHotKey` |
| `Thumbnails.swift` | Miniaturas de Quick Look con caché, `FileThumbnail` |
| `SettingsPane.swift` | Cómo funciona, gesto, tecla, atajo, comportamiento, abrir al iniciar sesión (`SMAppService`), idioma, actualizaciones, datos |
| `Settings.swift` | `UserDefaults` (`com.egluu.droppy`) |
| `Icon/AppIcon.html` | Fuente del icono. `scripts/make-icon.sh` lo renderiza con Chrome headless y genera `Resources/AppIcon.icns` (versionado; `build-app.sh` lo copia al bundle) e `Icon/AppIcon-1024.png` |
| `Theme.swift` | Colores y controles comunes (estilo oscuro de Wallpy/DemoImages) |
| `Updater.swift` | Autoactualización desde GitHub Releases con SHA-256 (idéntico al de DemoImages salvo nombres) |
| `Localization.swift` | Idiomas (en, es, ca): `tr()`, `Localizer`, tablas |

Datos: `~/Library/Application Support/Droppy/{shelves.json,Clips/<id>/}`.

## Convenciones

- Código, comentarios y commits en inglés. Interfaz en castellano, inglés y catalán. En la interfaz, «shelf» es **bandeja** (ca: safata).
- **Todo texto visible pasa por `tr("…")`** (o `tr("… %@ …", arg)`). La clave es el texto en castellano; añadir la traducción a `en` y `ca` en `Localization.swift` con los mismos `%@`/`%d`. Nunca interpolar dentro de un texto traducible.
- Estilo: usar `Theme` y sus componentes, nunca colores sueltos (salvo blancos con opacidad sobre el fondo translúcido de la bandeja).
- Estado de UI en tipos `@MainActor`; copiar, mover y comprimir fuera del hilo principal.
- Las bandejas **no copian** los archivos del usuario: solo URL + bookmark. Borrar = `recycle` (papelera). `removeItem` solo sobre lo que crea Droppy (clips, carpetas temporales).
- Mantener el README al día cuando cambian funciones visibles.

## Cosas a saber

- **Detección del arrastre**: `NSEvent.addGlobalMonitorForEvents` con `leftMouseDown/Dragged/Up` no pide permisos. Un arrastre cuenta si cambia `NSPasteboard(name: .drag).changeCount` respecto al `mouseDown` (mover ventanas o seleccionar no lo cambia). La tecla se lee de `event.modifierFlags` del propio evento de arrastre: un monitor de teclado global pediría Accesibilidad.
- **Bandeja fija** (`Shelf.isDocked`): una sola, guardada en `shelves.json` con `docked: true` (campo opcional). Vive en `NSScreen.screens.first`. Plegada es una pestaña de 8×72 en el lado y posición de `Settings.dockEdge`/`dockAlignment` (`ShelfPanel.tabFrame`); abierta, 260×340 pegada al mismo borde y centrada en vertical (`openDockFrame`). Al abrir, la ventana toma el tamaño abierto con un `setFrame` sin animar (animar el marco con SwiftUI dentro hace saltos) y el contenido entra deslizándose desde el borde (`contentShown`, `.transition(.move)`); al cerrar, sale deslizándose y después la ventana vuelve a pestaña. Se abre con el ratón encima, al entrar un arrastre, cuando `DragMonitor` ve un arrastre con contenido en `dockTriggerZone`, y con agitar, la tecla, ⌃⌥D o el menú (`revealDock(sticky: true)`: espera a que el ratón pase por ella, `waitsForVisit`). Se pliega 0,8 s después de que el ratón salga de la unión pestaña+tarjeta (si no hay arrastre, Quick Look ni trabajo), con un clic sin arrastre en otra app (`dockClickedOutside` en `leftMouseUp`) o con Esc. El temporizador va en modo `.default` para no plegarse con un menú abierto. Nunca se vacía al sacar archivos (solo `.delete` los quita). Con la bandeja fija activada, agitar/tecla/atajo **no** crean bandejas flotantes.
- **Orden y grupos**: globales en `Settings` (`sort`, `sortDescending`, `groupByKind`); ⇧-clic selecciona en el orden mostrado.
- **Ordenar por tipo**: solo el primer nivel de la carpeta; nunca carpetas (`OrganizeCategory(url:)` da `nil`), ocultos ni descargas a medias (`.crdownload`, `.download`, `.part`… y el archivo con nombre final si existe su `.part` al lado). `.dmg/.pkg/.mpkg/.iso` → `Instal·ladors`. Los nombres de carpeta no se traducen: así cambiar de idioma no crea carpetas nuevas. Cada ejecución se guarda (`OrganizeBatch`) y deshacer devuelve los archivos y borra las subcarpetas que creó si quedan vacías. Automático: `addedToDirectoryDate > autoOrganizeSince` (se pone a ahora al activarlo, al cambiar de carpeta y tras deshacer, para no volver a ordenar lo devuelto), espera 5 s sin cambios (y 2 min si pesa 0 bytes) y reintenta a los 6 s si quedan archivos llegando.
- **Agitar**: cambios de dirección horizontal con recorrido mínimo dentro de una ventana de tiempo (`ShakeSensitivity`). Si hay una bandeja vacía abierta se reutiliza (`shelfForDrag`).
- **Tamaño de las ventanas de bandeja**: lo decide la ventana. El `NSHostingView` va con `sizingOptions = []` y autoresizing, **sin Auto Layout**: con restricciones, `_changeWindowFrameFromConstraintsIfNecessary` imponía el mínimo de SwiftUI (la bandeja fija se quedaba en 252×268 como una caja translúcida en vez de la pestaña de 8×72, y se abría 252×529 arriba). Nunca `setFrame(…, animate: true)`: con SwiftUI dentro da saltos.
- **Sinks de `@Published` que tocan la ventana**: `@Published` avisa en `willSet`; redimensionar ahí fuerza un render con el valor viejo que se come la invalidación y la vista se queda desfasada (lista ampliada pintando aún el montón). Hacerlo con `DispatchQueue.main.async`.
- **Panel**: `.nonactivatingPanel` para no robar el foco a la app de la que se arrastra; `canBecomeKey` true para los atajos; `hidesOnDeactivate = false` (los NSPanel se esconden por defecto al desactivarse la app).
- **Arrastrar fuera**: SwiftUI `onDrag` solo da un elemento, por eso `FileDragArea` es AppKit. Máscara fuera de la app: copy/move/link/generic/delete; el Finder mueve en el mismo disco. Si se suelta sobre la propia bandeja no pasa nada. `.move` y `.delete` quitan siempre los archivos; las demás operaciones solo con «Quitar los archivos al sacarlos».
- **Soltar en la propia bandeja** se ignora en `ShelfDropView` (`draggingSource` en la misma ventana).
- `open -a Droppy a b` entrega una llamada a `application(_:open:)` por archivo: se agrupan 0,3 s en una sola bandeja.
- **Atajo global**: Carbon `RegisterEventHotKey` (sin permisos). ⌥⌘D no sirve (oculta el Dock).
- **Icono de la barra de menús**: `StatusDropView` encima del botón recibe los arrastres y reenvía los clics al botón.
- `SMAppService.mainApp` solo funciona bien con la app en `/Applications`.
- `NSHostingController` encoge la ventana de Ajustes: `sizingOptions = []`, `setContentSize` y después `setFrameAutosaveName`.
- **Runners de GitHub**: `macos-14` ya no existe. En `macos-15` el job puede quedarse en cola hasta que GitHub lo cancela por capacidad; relanzar con `gh run rerun <id>`.
- `main.swift` envuelve el arranque en `MainActor.assumeIsolated` porque `AppDelegate` es `@MainActor`.

## Pruebas manuales

- **Gancho de depuración** (solo `swift build` en debug, `#if DEBUG` en `AppDelegate`): ejecutar `.build/debug/Droppy` y enviar `DistributedNotificationCenter` `com.egluu.droppy.debug` con objeto `reveal`, `sticky`, `collapse`, `add` (Escritorio a la bandeja fija), `floating` (bandeja flotante con tres archivos), `expand` (lista/montón de la última flotante) `closeall`, `organize-window:<ruta>`, `organize-run:<ruta>` u `organize-undo`. Probar el ordenado en una carpeta del scratchpad, nunca en Descargas. El binario de debug usa el dominio de `UserDefaults` `Droppy`, no `com.egluu.droppy`. Con permiso de grabación de pantalla, `screencapture -x -R x,y,w,h` permite ver el resultado.

- No hay permiso de grabación de pantalla: `screencapture -l` falla. Para comprobar ventanas, `CGWindowListCopyWindowInfo` filtrando por propietario `Droppy` (las bandejas son ventanas de 210×236, o 290×380 en lista, en la capa 3); para comprobar datos, leer `shelves.json`.
- El gesto de agitar necesita ratón real; no se puede simular sin permiso de Accesibilidad.
- Las bandejas del usuario pueden tener sus archivos: si una prueba borra `~/Library/Application Support/Droppy`, copiarla antes y restaurarla después.
