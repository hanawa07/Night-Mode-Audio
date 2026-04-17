# 🌙 Night Mode Audio

macOS 시스템 오디오를 실시간으로 처리해서 **큰 소리는 줄이고, 작은 소리는 키워주는** 야간 모드 메뉴바 앱입니다.  
현재 배포 기준은 Python 프로토타입이 아니라 **Swift 네이티브 앱(`NativeMVP`)** 입니다.

## ✨ 주요 기능

- 메뉴바에서 시작/정지, 출력 장치 변경, 설정 창 열기
- 출력 장치 우선순위 리스트 기반 `자동 / 수동` 모드
- 연결 해제된 장치도 우선순위와 설정 유지
- 장치별 `압축 강도`, `볼륨 증폭`, `지연 모드` 저장
- 장치별 macOS 실제 출력 음량 저장 및 복원
- 현재 사용 장치와 편집 중인 장치 분리 표시

## 🚀 설치 방법

### 1. 사전 준비

이 앱은 가상 오디오 드라이버인 **BlackHole 2ch**가 필요합니다.

```bash
brew install blackhole-2ch
```

직접 설치하려면 [BlackHole 다운로드 페이지](https://existential.audio/blackhole/)를 사용해도 됩니다.

### 2. 앱 설치

1. GitHub Release에서 `NightModeAudio-native-macOS.zip`을 다운로드합니다.
2. 압축을 풉니다.
3. `NightModeAudio.app`을 `/Applications` 폴더로 옮깁니다.
4. 처음 실행할 때는 우클릭 후 `열기`를 선택합니다.
5. 권한 요청이 뜨면 허용합니다.

### 3. 실행 후 기본 사용 흐름

1. macOS 기본 출력 장치를 `BlackHole 2ch`로 설정합니다.
2. 메뉴바에서 `Night Mode Audio`를 실행합니다.
3. 메뉴에서 `야간 모드 시작`을 누릅니다.
4. 설정 창에서 출력 모드, 우선순위, 장치별 처리 설정을 조절합니다.

## ⚠️ 문제 해결

앱이 `손상되었거나 열 수 없습니다`처럼 보이면:

```bash
xattr -cr /Applications/NightModeAudio.app
```

소리가 안 들리면 먼저 아래를 확인하세요.

- `BlackHole 2ch`가 설치되어 있는지
- macOS 기본 출력이 `BlackHole 2ch`인지
- 메뉴바 앱에서 야간 모드가 시작된 상태인지
- 설정 창에서 현재 사용 장치와 편집 중인 장치를 헷갈리고 있지 않은지

## 🧪 개발

네이티브 앱 소스는 `NativeMVP/` 아래에 있습니다.

주요 파일:

- `NativeMVP/Package.swift`
- `NativeMVP/Sources/NightModeNativeCore/`
- `NativeMVP/Sources/NightModeNativeCLI/main.swift`
- `NativeMVP/Sources/NightModeNativeApp/main.swift`
- `NativeMVP/Docs/PLAN.md`

### 로컬 실행

장치 탐지만 확인:

```bash
cd NativeMVP
swift run NightModeNativeMVP probe
```

메뉴바 앱 실행:

```bash
cd NativeMVP
swift run NightModeNativeApp
```

### 배포용 앱 만들기

```bash
cd NativeMVP
./build_native_app.sh
```

생성 결과:

- `NativeMVP/dist/NightModeAudio.app`
- `NativeMVP/NightModeAudio-native-macOS.zip`

로컬 설치:

```bash
cd NativeMVP
./install_native_app.sh
```

## 🛠️ 현재 UX 기준

- 메뉴바 드롭다운은 빠른 조작만 담당합니다.
- 자세한 설정은 별도 설정 창에서 합니다.
- 우선순위 리스트에서 장치를 선택하면, 연결 해제된 장치도 미리 편집할 수 있습니다.
- `현재 사용` 장치와 `편집 중` 장치를 따로 표시합니다.
- `모든 장치에 적용`은 확인 후에만 실행됩니다.

## ⚠️ 참고

- 현재 릴리즈 기준 앱은 `NativeMVP` 네이티브 앱입니다.
- 루트의 Python 파일들은 이전 프로토타입 흔적이므로, 최신 사용자 기준 문서는 이 README와 GitHub Release를 따르면 됩니다.
