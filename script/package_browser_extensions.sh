#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/dist/browser-extensions"
STAGING_DIR="$PROJECT_ROOT/.build/browser-extensions"

rm -rf "$STAGING_DIR" "$OUTPUT_DIR"
mkdir -p "$STAGING_DIR/chromium" "$STAGING_DIR/firefox" "$OUTPUT_DIR"

for browser in chromium firefox; do
  cp "$PROJECT_ROOT"/BrowserExtensions/shared/* "$STAGING_DIR/$browser/"
  mkdir -p "$STAGING_DIR/$browser/icons"
  /usr/bin/sips -z 128 128 "$PROJECT_ROOT/Docs/Assets/app-icon.png" --out "$STAGING_DIR/$browser/icons/icon-128.png" >/dev/null
  cp "$PROJECT_ROOT/BrowserExtensions/$browser-manifest.json" "$STAGING_DIR/$browser/manifest.json"
done

(
  cd "$STAGING_DIR/chromium"
  /usr/bin/zip -q -r "$OUTPUT_DIR/kite-chromium.zip" .
)
(
  cd "$STAGING_DIR/firefox"
  /usr/bin/zip -q -r "$OUTPUT_DIR/kite-firefox.zip" .
)

if xcrun --find safari-web-extension-converter >/dev/null 2>&1; then
  cp "$PROJECT_ROOT/BrowserExtensions/safari-manifest.json" "$STAGING_DIR/chromium/manifest.json"
  xcrun safari-web-extension-converter \
    "$STAGING_DIR/chromium" \
    --project-location "$STAGING_DIR/Safari" \
    --app-name "Kite Safari" \
    --bundle-identifier "com.chenli.kite.safari" \
    --swift --macos-only --copy-resources --no-open --no-prompt --force >/dev/null
  SAFARI_PROJECT="$STAGING_DIR/Safari/Kite Safari/Kite Safari.xcodeproj/project.pbxproj"
  /usr/bin/sed -i '' \
    's/com\.chenli\.kite\.Kite-Safari/com.chenli.kite.safari/g' \
    "$SAFARI_PROJECT"
  (
    cd "$STAGING_DIR/Safari"
    /usr/bin/zip -q -r "$OUTPUT_DIR/kite-safari-project.zip" .
  )
fi

printf 'Browser extension packages: %s\n' "$OUTPUT_DIR"
