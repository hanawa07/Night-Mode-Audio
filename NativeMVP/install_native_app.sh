#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NightModeAudio.app"
ZIP_NAME="NightModeAudio-native-macOS.zip"
SOURCE="$SCRIPT_DIR/dist/$APP_NAME"
DEST="/Applications/$APP_NAME"

echo "=== Night Mode Audio 네이티브 앱 설치 ==="

if [ ! -d "$SOURCE" ] && [ -f "$SCRIPT_DIR/$ZIP_NAME" ]; then
    echo "압축본에서 앱을 복원합니다..."
    rm -rf "$SCRIPT_DIR/dist/$APP_NAME"
    mkdir -p "$SCRIPT_DIR/dist"
    ditto -x -k "$SCRIPT_DIR/$ZIP_NAME" "$SCRIPT_DIR/dist"
fi

if [ ! -d "$SOURCE" ]; then
    echo "오류: 빌드된 앱($SOURCE) 또는 압축본($SCRIPT_DIR/$ZIP_NAME)을 찾지 못했습니다."
    exit 1
fi

pkill -f NightModeAudio || true

if [ -d "$DEST" ]; then
    rm -rf "$DEST"
fi

cp -R "$SOURCE" /Applications/
xattr -cr "$DEST" || true
touch "$DEST"
touch "$DEST/Contents/Info.plist"

echo "설치 완료: $DEST"
open /Applications
