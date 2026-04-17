#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="NightModeAudio.app"
EXECUTABLE_NAME="NightModeAudio"
PRODUCT_NAME="NightModeNativeApp"
BUNDLE_ID="com.hanawa07.NightModeAudio"
ZIP_NAME="NightModeAudio-native-macOS.zip"
DIST_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$PROJECT_ROOT/app_icon.png"
MENU_ICON_SOURCE="$PROJECT_ROOT/menu_icon.png"
MENU_ICON_ON_SOURCE="$PROJECT_ROOT/menu_icon_on.png"
ICONSET_DIR="$SCRIPT_DIR/.build/AppIcon.iconset"
ICON_FILE="$RESOURCES_DIR/AppIcon.icns"

echo "=== Night Mode Audio 네이티브 앱 빌드 ==="

rm -rf "$APP_BUNDLE" "$SCRIPT_DIR/$ZIP_NAME" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swift build -c release --product "$PRODUCT_NAME"

PRODUCT_PATH="$SCRIPT_DIR/.build/release/$PRODUCT_NAME"
if [ ! -x "$PRODUCT_PATH" ]; then
    echo "오류: 빌드된 실행 파일을 찾지 못했습니다: $PRODUCT_PATH"
    exit 1
fi

cp "$PRODUCT_PATH" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if [ -f "$ICON_SOURCE" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    mkdir -p "$ICONSET_DIR"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
fi

if [ -f "$MENU_ICON_SOURCE" ]; then
    cp "$MENU_ICON_SOURCE" "$RESOURCES_DIR/menu_icon.png"
fi

if [ -f "$MENU_ICON_ON_SOURCE" ]; then
    cp "$MENU_ICON_ON_SOURCE" "$RESOURCES_DIR/menu_icon_on.png"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>NightModeAudio</string>
    <key>CFBundleDisplayName</key>
    <string>NightModeAudio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>0.2.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>시스템 오디오 처리를 위해 오디오 입력 접근이 필요합니다.</string>
$(if [ -f "$ICON_FILE" ]; then cat <<'ICON'
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
ICON
fi)
</dict>
</plist>
PLIST

echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$SCRIPT_DIR/$ZIP_NAME"

echo ""
echo "빌드 완료:"
echo "앱: $APP_BUNDLE"
echo "압축본: $SCRIPT_DIR/$ZIP_NAME"
