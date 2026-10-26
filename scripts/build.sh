#!/bin/bash
# Builds "Disk Alert.app" (universal: Apple silicon and Intel) into ./build.
# Needs macOS with Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# Set for alpha builds, e.g. "alpha.18". The app shows it next to the version and
# CFBundleShortVersionString stays plain numbers, as macOS expects.
PRERELEASE="${PRERELEASE:-}"
FULL_VERSION="$VERSION${PRERELEASE:+-$PRERELEASE}"
MIN_OS="15.0"
OUT="build"
APP="$OUT/Disk Alert.app"
AGENT="$APP/Contents/Library/LoginItems/Disk Alert Agent.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$AGENT/Contents/MacOS" "$OUT/obj"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
echo "Xcode: $(xcodebuild -version 2>/dev/null | tr "\n" " ")"
echo "Swift: $(xcrun swiftc --version 2>&1 | head -1)"

compile() { # compile <output> <sources...>
  local name="$1"; shift
  local slices=()
  for arch in arm64 x86_64; do
    xcrun swiftc -sdk "$SDK" -target "$arch-apple-macos$MIN_OS" -swift-version 5 -O \
      -module-name "$(basename "$name")" -o "$OUT/obj/$(basename "$name")-$arch" "$@"
    slices+=("$OUT/obj/$(basename "$name")-$arch")
  done
  lipo -create -output "$name" "${slices[@]}"
}

echo "Building agent…"
compile "$AGENT/Contents/MacOS/DiskAlertAgent" Sources/Shared/*.swift Sources/Agent/*.swift

echo "Building app…"
compile "$APP/Contents/MacOS/DiskAlert" Sources/Shared/*.swift Sources/App/*.swift

echo "Drawing icon…"
xcrun swift scripts/make-icon.swift "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$AGENT/Contents/Resources"
cp "$APP/Contents/Resources/AppIcon.icns" "$AGENT/Contents/Resources/AppIcon.icns"

echo "Adding bundled sounds…"
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Disk Alert</string>
  <key>CFBundleDisplayName</key><string>Disk Alert</string>
  <key>CFBundleIdentifier</key><string>app.diskalert</string>
  <key>CFBundleExecutable</key><string>DiskAlert</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>DAPrerelease</key><string>$PRERELEASE</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 open-luc. MIT License.</string>
</dict></plist>
EOF

cat > "$AGENT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Disk Alert</string>
  <key>CFBundleDisplayName</key><string>Disk Alert</string>
  <key>CFBundleIdentifier</key><string>app.diskalert.agent</string>
  <key>CFBundleExecutable</key><string>DiskAlertAgent</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
EOF

echo "Signing (ad hoc)…"
codesign --force --sign - --timestamp=none "$AGENT"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "Packaging disk image…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Disk Alert.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Disk-Alert-$FULL_VERSION.dmg"
hdiutil create -volname "Disk Alert $FULL_VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Done: $DMG"
