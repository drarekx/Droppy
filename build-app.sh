#!/bin/zsh
# Builds Droppy.app (release, universal) into ./build
set -euo pipefail
cd "$(dirname "$0")"

NAME=Droppy
APP=build/$NAME.app
VERSION=${VERSION:-1.0.0}
BUILD=${BUILD:-1}
# Universal builds need full Xcode (xcbuild); with only the Command Line Tools,
# build for this Mac's architecture.
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Xcode not found: building for $(uname -m) only"
    ARCH_FLAGS=()
fi
swift build -c release "${ARCH_FLAGS[@]}"
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/$NAME

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# Icon source: Icon/AppIcon.html, rendered by scripts/make-icon.sh.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# LSUIElement: menu bar app, no Dock icon. NSServices adds "Add to Droppy" to
# the Services menu (Finder right-click → Services, or any app with a selection).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.egluu.droppy</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Files</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>public.item</string></array>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Add to Droppy</string></dict>
            <key>NSMessage</key><string>addToDroppy</string>
            <key>NSPortName</key><string>$NAME</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendTypes</key>
            <array>
                <string>public.file-url</string>
                <string>NSFilenamesPboardType</string>
                <string>public.utf8-plain-text</string>
                <string>public.url</string>
                <string>public.png</string>
                <string>public.tiff</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd build && rm -f $NAME.zip && ditto -c -k --keepParent $NAME.app $NAME.zip)
echo "Built $APP ($VERSION) and build/$NAME.zip"
