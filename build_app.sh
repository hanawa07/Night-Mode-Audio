#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="NightModeAudio.app"
ZIP_NAME="NightModeAudio-macOS.zip"
PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python"

if [ ! -x "$PYTHON_BIN" ]; then
    echo "오류: 가상환경 Python을 찾을 수 없습니다: $PYTHON_BIN"
    echo "먼저 .venv를 준비하고 PyInstaller, rumps, sounddevice, numpy를 설치하세요."
    exit 1
fi

echo "=== Night Mode macOS 앱 빌드 ==="

rm -rf "$SCRIPT_DIR/build" "$SCRIPT_DIR/dist/$APP_NAME" "$SCRIPT_DIR/$ZIP_NAME"

"$PYTHON_BIN" -m PyInstaller --noconfirm NightModeAudio.spec

if [ ! -d "$SCRIPT_DIR/dist/$APP_NAME" ]; then
    echo "오류: 앱 번들 생성에 실패했습니다."
    exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$SCRIPT_DIR/dist/$APP_NAME" "$SCRIPT_DIR/$ZIP_NAME"

echo ""
echo "빌드 완료:"
echo "앱: $SCRIPT_DIR/dist/$APP_NAME"
echo "압축본: $SCRIPT_DIR/$ZIP_NAME"
