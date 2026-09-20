#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="CodexBar"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  xcodebuild \
    -project "$ROOT_DIR/CodexBar.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    build \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
    CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-NO}" \
    CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app was not built: $APP_PATH" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGING_DIR/$APP_NAME.app/Contents/Info.plist")"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Created $DMG_PATH"
