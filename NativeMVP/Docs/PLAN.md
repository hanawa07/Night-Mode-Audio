# Native MVP Plan

목표:
- Python + PortAudio 경로 대신 Swift 네이티브 엔진으로 저지연 가능성을 먼저 검증한다.
- 첫 단계에서는 UI보다 `BlackHole 입력 -> 실제 출력` 패스스루 엔진만 확인한다.

1단계 범위:
- CoreAudio 장치 목록 조회
- `BlackHole 2ch` 입력 찾기
- 실제 출력 장치 하나 선택
- Audio Unit HAL 기반 CLI 패스스루 엔진 시작/정지

제외:
- 메뉴바 UI
- 자동 전환
- 압축 파라미터 UI
- 릴리즈 배포

검증 포인트:
- 유선/USB 출력 기준으로 현재 Python 버전보다 딜레이 체감이 줄어드는지
- 블루투스 출력에서도 연결 직후 지연 변동이 줄어드는지

로컬 실행 예시:

```bash
cd NativeMVP
swift run NightModeNativeMVP probe
swift run NightModeNativeMVP passthrough AppleUSBAudioEngine:ACTIONS:Pebble\ V3:...:1
```
