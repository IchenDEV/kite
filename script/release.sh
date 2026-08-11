#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
IDENTITY="${SUPERDD_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${SUPERDD_NOTARY_PROFILE:-}"

if [[ -z "$VERSION" || -z "$IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
  echo "usage: SUPERDD_CODESIGN_IDENTITY='Developer ID Application: …' SUPERDD_NOTARY_PROFILE=profile $0 <version>" >&2
  exit 2
fi

export SUPERDD_VERSION="$VERSION"
export SUPERDD_BUILD_CONFIGURATION="release"
export SUPERDD_CODESIGN_IDENTITY="$IDENTITY"

"$ROOT_DIR/script/build_and_run.sh" --package

APP="$ROOT_DIR/dist/SuperDD.app"
RELEASE_DIR="$ROOT_DIR/dist/release-$VERSION"
ZIP="$RELEASE_DIR/SuperDD-$VERSION-$(uname -m).zip"
DMG="$RELEASE_DIR/SuperDD-$VERSION-$(uname -m).dmg"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
hdiutil create -volname "Super DD" -srcfolder "$APP" -ov -format UDZO "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
hdiutil verify "$DMG"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt
)

echo "Release artifacts: $RELEASE_DIR"
