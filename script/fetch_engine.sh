#!/usr/bin/env bash
set -euo pipefail

ENGINE_VERSION="2.5.5"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/Resources/Engine"
ENGINE_PATH="$ENGINE_DIR/aria2-next"

case "$(uname -m)" in
  arm64)
    ASSET="aria2-next-$ENGINE_VERSION-macos-arm64"
    EXPECTED_SHA="1417eec59edba6ac436b5f3b1bbcc2add01696d62333e8de8c3900677bd45926"
    ;;
  x86_64)
    ASSET="aria2-next-$ENGINE_VERSION-macos-x86_64"
    EXPECTED_SHA="49a39dd624d45f693a41ecca0e6359ec0bd91df9efa16cf994f2f200aa45d415"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$ENGINE_DIR"

if [[ -x "$ENGINE_PATH" ]]; then
  CURRENT_SHA="$(shasum -a 256 "$ENGINE_PATH" | awk '{print $1}')"
  if [[ "$CURRENT_SHA" == "$EXPECTED_SHA" ]]; then
    exit 0
  fi
fi

TEMP_PATH="$ENGINE_DIR/$ASSET.tmp"
URL="https://github.com/AnInsomniacy/aria2-next/releases/download/v$ENGINE_VERSION/$ASSET"
curl --fail --location --retry 3 --output "$TEMP_PATH" "$URL"

ACTUAL_SHA="$(shasum -a 256 "$TEMP_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "aria2-next checksum mismatch: expected $EXPECTED_SHA, got $ACTUAL_SHA" >&2
  exit 1
fi

mv "$TEMP_PATH" "$ENGINE_PATH"
chmod 755 "$ENGINE_PATH"
echo "Fetched aria2-next $ENGINE_VERSION for $(uname -m)."
