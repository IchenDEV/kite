#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SuperDD"
BUNDLE_ID="com.chenli.superdd"
MIN_SYSTEM_VERSION="26.0"
APP_VERSION="${SUPERDD_VERSION:-0.2.0}"
BUILD_CONFIGURATION="${SUPERDD_BUILD_CONFIGURATION:-debug}"
CODESIGN_IDENTITY="${SUPERDD_CODESIGN_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_HELPERS="$APP_RESOURCES/Helpers"
APP_CLI="$APP_RESOURCES/CLI"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -f "$APP_BUNDLE/Contents/Resources/Engine/aria2-next" >/dev/null 2>&1 || true

"$ROOT_DIR/script/fetch_engine.sh"
"$ROOT_DIR/script/generate_icon.sh"
"$ROOT_DIR/script/package_browser_extensions.sh"
swift build --package-path "$ROOT_DIR" --configuration "$BUILD_CONFIGURATION"
BUILD_DIR="$(swift build --package-path "$ROOT_DIR" --configuration "$BUILD_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES/Engine" "$APP_RESOURCES/Legal" "$APP_HELPERS" "$APP_CLI" "$APP_RESOURCES/BrowserExtensions"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_DIR/superdd-plugin-host" "$APP_HELPERS/superdd-plugin-host"
cp "$BUILD_DIR/superddctl" "$APP_CLI/superddctl"
cp "$ROOT_DIR/Resources/Engine/aria2-next" "$APP_RESOURCES/Engine/aria2-next"
cp "$ROOT_DIR/Legal/aria2-next-GPLv2.txt" "$APP_RESOURCES/Legal/aria2-next-GPLv2.txt"
cp "$ROOT_DIR/.build/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp -R "$ROOT_DIR/Resources/zh-Hans.lproj" "$APP_RESOURCES/zh-Hans.lproj"
cp "$ROOT_DIR"/dist/browser-extensions/*.zip "$APP_RESOURCES/BrowserExtensions/"
chmod 755 "$APP_BINARY" "$APP_RESOURCES/Engine/aria2-next" "$APP_HELPERS/superdd-plugin-host" "$APP_CLI/superddctl"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Super DD</string>
  <key>CFBundleDisplayName</key>
  <string>Super DD</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>zh-Hans</string></array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026. aria2-next is distributed under GPLv2.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>Super DD Download Links</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>superdd</string>
        <string>magnet</string>
        <string>ed2k</string>
        <string>thunder</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>BitTorrent File</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>torrent</string></array>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$ROOT_DIR/Resources/PluginHost.entitlements" --sign "$CODESIGN_IDENTITY" "$APP_HELPERS/superdd-plugin-host"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_CLI/superddctl"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_RESOURCES/Engine/aria2-next"
  codesign --force --options runtime --timestamp --entitlements "$ROOT_DIR/Resources/SuperDD.entitlements" --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
  codesign --force --entitlements "$ROOT_DIR/Resources/PluginHost.entitlements" --sign - "$APP_HELPERS/superdd-plugin-host"
  codesign --force --sign - "$APP_CLI/superddctl"
  codesign --force --sign - "$APP_RESOURCES/Engine/aria2-next"
  codesign --force --entitlements "$ROOT_DIR/Resources/SuperDD.entitlements" --sign - "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    codesign --verify --deep --strict "$APP_BUNDLE"
    ;;
  package|--package)
    codesign --verify --deep --strict "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--package]" >&2
    exit 2
    ;;
esac
