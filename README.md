# Droppy

Bandejas flotantes para mover archivos en macOS. Empieza a arrastrar archivos, agita el ratón y aparece una **bandeja**: suéltalos ahí y esperan mientras cambias de carpeta, de app o de escritorio. Cuando tengas el destino a la vista, arrástralos desde la bandeja, todos a la vez o uno a uno. Como una lista de espera para mover cosas.

## Instalar

Abre Terminal y pega:

```sh
curl -fsSL https://raw.githubusercontent.com/drarekx/Droppy/main/install.sh | bash
```

El instalador descarga la última versión, la copia en `/Applications` y la abre. Droppy vive en la barra de menús (icono de bandeja); no sale en el Dock.

Droppy se actualiza sola: busca versiones nuevas al arrancar y una vez al día (o desde el icono → **Buscar actualizaciones…**), comprueba la descarga con su SHA-256 y se reinicia ya actualizada. Se puede desactivar en Ajustes. Volver a ejecutar el comando de instalación también actualiza.

**Instalación manual:** descarga `Droppy.zip` de [Releases](https://github.com/drarekx/Droppy/releases/latest), descomprímelo y mueve `Droppy.app` a Aplicaciones. La app no está notarizada, así que la primera vez ábrela con clic derecho → **Abrir**.

Requisitos: macOS 14 (Sonoma) o posterior. Apple Silicon o Intel.

## Qué hace

- **Abrir una bandeja**
  - Agitando el ratón mientras arrastras archivos, texto o imágenes desde cualquier app (sensibilidad baja, media o alta).
  - Pulsando una tecla mientras arrastras (⌃, ⌥ o ⇧; desactivado por defecto).
  - Con el atajo **⌃⌥D**, desde cualquier app: bandeja vacía donde esté el ratón.
  - Soltando archivos en el icono de la barra de menús, con «Abrir con» → Droppy, o con el menú **Servicios → Add to Droppy**.
  - Desde el icono: **Nueva bandeja** o **Nueva bandeja con lo copiado**.
- **Bandeja fija**: una pestaña fina en el borde de la pantalla (izquierda o derecha; arriba, centro o abajo, en Ajustes). Se abre al pasar el ratón, al arrastrar archivos hasta ella, al agitar el ratón o pulsar la tecla mientras arrastras, o con ⌃⌥D; se desliza desde el borde y queda pegada a él, centrada en vertical. Lo que dejes se queda (aunque lo arrastres a otro sitio) hasta que lo quites tú, y sigue ahí al reiniciar. Se pliega al apartar el ratón, con un clic fuera o con Esc. Con la bandeja fija desactivada, esos gestos abren bandejas flotantes nuevas.
- **Guardar en la bandeja**: archivos y carpetas (la bandeja solo apunta a ellos, no los copia, y los sigue si se mueven en el Finder), archivos prometidos (adjuntos de Mail, Fotos…), y también texto, imágenes y enlaces, que se guardan como `.txt`, `.png` y `.webloc`. Se pueden tener varias bandejas a la vez; flotan sobre las ventanas y en todos los escritorios.
- **Sacar de la bandeja**: arrastrar el montón se lleva todos los archivos; «Ver todos» los lista y cada fila (o la selección, con ⌘-clic y ⇧-clic) se arrastra por separado. En el Finder, dentro del mismo disco se **mueven** (⌥ copia, como siempre). Al sacarlos, dejan la bandeja, y la bandeja vacía se cierra (las dos cosas se pueden desactivar).
- **Ordenar y agrupar** la lista (botón ⇅ o Ajustes): por orden de llegada, nombre, tamaño o tipo, ascendente o descendente, y agrupada por tipo (carpetas, imágenes, PDF, documentos, hojas de cálculo, presentaciones, vídeos, audio, comprimidos, código, apps) con lo que ocupa cada grupo.
- **Ordenar carpetas por tipo** (icono de la barra de menús → «Ordenar Descargas por tipo…», «Ordenar otra carpeta…», o clic derecho sobre una carpeta de una bandeja): mueve los archivos a subcarpetas con nombre en catalán (`Imatges`, `PDF`, `Documents`, `Fulls de càlcul`, `Presentacions`, `Vídeos`, `Àudio`, `Comprimits`, `Instal·ladors`, `Codi`, `Apps`, `Altres`). Antes se ve qué va a cada una y se eligen los tipos. No toca carpetas, archivos ocultos ni descargas a medias; si el nombre ya existe, pone «nombre 2». **Deshacer** devuelve todo a su sitio. En Ajustes se puede **ordenar automáticamente** la carpeta (Descargas por defecto): solo los archivos que llegan después de activarlo, cuando terminan de descargarse. La primera vez macOS pide permiso para acceder a Descargas.
- **Acciones** (botón «…» o clic derecho): abrir, vista rápida, mostrar en Finder, copiar, copiar o mover a una carpeta, comprimir en ZIP, compartir, AirDrop, pasar a una bandeja nueva, quitar de la bandeja, mover a la papelera, pegar y vaciar.
- **Teclado** con la bandeja activa: Espacio (vista rápida), ⏎ (abrir), ⌘C, ⌘V, ⌘A, ⌫ (quitar seleccionados), ⌘⌫ (papelera), Esc / ⌘W (cerrar).
- **Bandejas recientes**: al cerrar una bandeja con archivos se guarda en el menú del icono para reabrirla. Las bandejas abiertas se recuperan al volver a abrir la app.
- **Abrir al iniciar sesión** e **idiomas** (castellano, inglés y catalán) en Ajustes.

## Dónde guarda las cosas

- Bandejas (abiertas y recientes): `~/Library/Application Support/Droppy/shelves.json`
- Texto, imágenes y enlaces soltados: `~/Library/Application Support/Droppy/Clips/<id de la bandeja>/` (se borran al descartar la bandeja)
- Historial de ordenaciones (para deshacer): `~/Library/Application Support/Droppy/organize-history.json`
- Ajustes: `defaults read com.egluu.droppy`

## Desinstalar

```sh
osascript -e 'quit app "Droppy"'
rm -rf /Applications/Droppy.app ~/Library/Application\ Support/Droppy
defaults delete com.egluu.droppy
```

## Compilar desde el código

```sh
git clone https://github.com/drarekx/Droppy.git
cd Droppy
./build-app.sh          # deja build/Droppy.app y build/Droppy.zip
open build/Droppy.app
```

Con Xcode 16+ el binario es universal (arm64 + x86_64); solo con las Command Line Tools se compila para la arquitectura del Mac.

Para publicar una versión nueva, crea y sube una etiqueta; GitHub Actions compila la app y crea el release con el zip:

```sh
git tag v1.0.1 && git push origin v1.0.1
```
