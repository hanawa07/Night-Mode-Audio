#!/bin/bash
echo "=== 야간 모드 오디오 앱 설치 ==="

# 스크립트가 있는 경로를 기준으로 설정
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NightModeAudio.app"
SOURCE="$SCRIPT_DIR/dist/$APP_NAME"
DEST="/Applications/$APP_NAME"

# 1. 앱 이동
if [ -d "$SOURCE" ]; then
    echo "1. 앱을 응용 프로그램 폴더로 이동합니다..."
    
    # 기존 앱 프로세스 종료 (강제)
    pkill -f NightModeAudio || true
    
    # 기존 앱 제거
    if [ -d "$DEST" ]; then
        rm -rf "$DEST"
    fi
    
    cp -R "$SOURCE" /Applications/
    
    # 격리 속성 제거 (실행 불가 문제 방지)
    xattr -cr "$DEST"
    
    echo "   -> 이동 완료: $DEST"
else
    echo "오류: 빌드된 앱($SOURCE)을 찾을 수 없습니다."
    exit 1
fi

# 2. 시작 프로그램 등록 (선택 사항)
echo "2. 로그인 시 자동 실행 등록을 시도합니다..."
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/NightModeAudio.app", hidden:false}' 2>/dev/null

if [ $? -eq 0 ]; then
    echo "   -> 등록 성공!"
else
    echo "   -> (참고) 자동 권한 문제로 등록되지 않았을 수 있습니다. 필요하면 수동으로 등록하세요."
fi

# 3. 완료 안내
echo ""
echo "=== 설치 완료! ==="
# 아이콘 캐시 갱신 강제
touch /Applications/NightModeAudio.app
touch /Applications/NightModeAudio.app/Contents/Info.plist

echo "이제 Launchpad나 Spotlight(Cmd+Space)에서 'NightModeAudio'를 검색해 실행하세요."
echo "상단 메뉴바(시계 옆)에 🌙 야간 모드 아이콘이 뜰 겁니다!"
echo ""
open /Applications
