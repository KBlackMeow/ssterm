#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SSTerm"
VERSION="$(grep '^version:' "$REPO_ROOT/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
BUILD_DIR="$REPO_ROOT/build/macos/Build/Products/Release"
DIST_DIR="$REPO_ROOT/dist"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "==> Building $APP_NAME $VERSION"
cd "$REPO_ROOT"
flutter build macos --release

echo "==> Preparing dist/"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "==> Creating DMG"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 180 170 \
  --app-drop-link 480 170 \
  --no-internet-enable \
  "$DIST_DIR/$DMG_NAME" \
  "$BUILD_DIR/${APP_NAME}.app"

echo "==> Done: dist/$DMG_NAME"
