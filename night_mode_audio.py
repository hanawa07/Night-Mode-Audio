import rumps
import sounddevice as sd
import numpy as np
import threading
import time
import sys
import os
import logging
import plistlib
from pathlib import Path

# PyInstaller에서 리소스 경로 찾기 위한 함수
def resource_path(relative_path):
    if hasattr(sys, '_MEIPASS'):
        return os.path.join(sys._MEIPASS, relative_path)
    
    if getattr(sys, 'frozen', False):
        # macOS onedir 구조 대응
        base_path = os.path.dirname(sys.executable)
        
        # 1. 같은 폴더 확인 (Contents/MacOS)
        path = os.path.join(base_path, relative_path)
        if os.path.exists(path): return path
        
        # 2. Resources 폴더 확인 (Contents/Resources)
        path = os.path.join(base_path, "..", "Resources", relative_path)
        if os.path.exists(path): return path

    return os.path.join(os.path.abspath("."), relative_path)

# 앱 이름 및 아이콘 설정 (빌드 시 아이콘 적용됨)
APP_NAME = "Night Mode"

# 디버그 로깅 설정 (사용자 홈 디렉토리에 로그 파일 생성)
log_file = os.path.expanduser("~/night_mode_debug.log")
logging.basicConfig(filename=log_file, level=logging.DEBUG, 
                    format='%(asctime)s - %(levelname)s - %(message)s')

class NightModeApp(rumps.App):
    def __init__(self):
        logging.info("App initializing...")
        try:
            super(NightModeApp, self).__init__(APP_NAME, icon=resource_path("menu_icon.png"), quit_button=None)
            logging.info("Rumps init successful")
        except Exception as e:
            logging.error(f"Rumps init failed: {e}")
            raise e
        
        self.is_running = False
        self.stream = None
        self.devices = []
        self.input_device = None
        self.output_device = None
        
        # 압축 기본 설정
        self.threshold_db = -20.0
        self.makeup_gain_db = 10.0
        self.ratio = 4.0
        
        self.build_menu()
        self.refresh_devices(None)
        
        # 자동 실행 상태 초기화
        self.menu["설정"]["로그인 시 자동 실행"].state = self.is_auto_start_enabled()


    def build_menu(self):
        logging.info("Building menu...")
        try:
            # 1. Main Toggle
            toggle_item = rumps.MenuItem("야간 모드 시작", callback=self.toggle_processing)

            # 2. Threshold Submenu
            threshold_menu = rumps.MenuItem("압축 강도 (Threshold)")
            threshold_menu.add(rumps.MenuItem("약하게 (-10dB)", callback=self.set_threshold_weak))
            threshold_menu.add(rumps.MenuItem("보통 (-20dB)", callback=self.set_threshold_normal))
            threshold_menu.add(rumps.MenuItem("강하게 (-30dB)", callback=self.set_threshold_strong))

            # 3. Gain Submenu
            gain_menu = rumps.MenuItem("볼륨 증폭 (Gain)")
            gain_menu.add(rumps.MenuItem("낮게 (0dB)", callback=self.set_gain_low))
            gain_menu.add(rumps.MenuItem("보통 (+10dB)", callback=self.set_gain_normal))
            gain_menu.add(rumps.MenuItem("높게 (+20dB)", callback=self.set_gain_high))

            # 4. Output Submenu
            output_menu = rumps.MenuItem("출력 장치 선택")
            output_menu.add(rumps.MenuItem("목록 새로고침", callback=self.refresh_devices))
            output_menu.add(rumps.separator)
            
            # 5. Settings Submenu
            settings_menu = rumps.MenuItem("설정")
            settings_menu.add(rumps.MenuItem("로그인 시 자동 실행", callback=self.toggle_auto_start))

            # Assign to app.menu
            self.menu = [
                toggle_item,
                rumps.separator,
                threshold_menu,
                gain_menu,
                rumps.separator,
                output_menu,
                settings_menu,
                rumps.separator,
                rumps.MenuItem("종료", callback=rumps.quit_application)
            ]
            
            # 초기 체크 설정
            self.menu["압축 강도 (Threshold)"]["보통 (-20dB)"].state = True
            self.menu["볼륨 증폭 (Gain)"]["보통 (+10dB)"].state = True
            logging.info("Menu built successfully")
        except Exception as e:
            logging.error(f"Menu build failed: {e}")
            raise e

    # --- 자동 실행 관리 ---
    def get_plist_path(self):
        return Path.home() / "Library" / "LaunchAgents" / "com.lizstudio.nightmodeaudio.plist"

    def is_auto_start_enabled(self):
        return self.get_plist_path().exists()

    def toggle_auto_start(self, sender):
        plist_path = self.get_plist_path()
        if sender.state:
            # 비활성화
            if plist_path.exists():
                plist_path.unlink()
            sender.state = False
            logging.info("Auto-start disabled")
        else:
            # 활성화
            try:
                # 현재 실행 중인 앱 경로 찾기
                if getattr(sys, 'frozen', False):
                    # .app 패키지 안의 실제 실행 파일 경로는 Contents/MacOS/NightModeAudio 임
                    # 하지만 Launch Agent는 .app 자체를 여는 것이 나을 수 있음
                    executable_path = sys.executable
                    # 만약 .app 내부에 있다면 패키지 경로를 사용
                    if ".app/Contents/MacOS/" in executable_path:
                        app_path = executable_path.split(".app/Contents/MacOS/")[0] + ".app"
                    else:
                        app_path = executable_path
                else:
                    app_path = os.path.abspath(sys.argv[0])

                plist_data = {
                    "Label": "com.lizstudio.nightmodeaudio",
                    "ProgramArguments": ["/usr/bin/open", "-n", app_path],
                    "RunAtLoad": True,
                    "ProcessType": "Interactive"
                }
                
                plist_path.parent.mkdir(parents=True, exist_ok=True)
                with open(plist_path, 'wb') as f:
                    plistlib.dump(plist_data, f)
                
                sender.state = True
                logging.info(f"Auto-start enabled for: {app_path}")
            except Exception as e:
                logging.error(f"Failed to enable auto-start: {e}")
                rumps.alert("오류", f"자동 실행 설정에 실패했습니다: {e}")

    # --- 장치 관리 ---
    def refresh_devices(self, _):
        self.devices = sd.query_devices()
        
        # 출력 메뉴 리빌딩
        out_menu = self.menu["출력 장치 선택"]
        out_menu.clear()
        out_menu.add(rumps.MenuItem("목록 새로고침", callback=self.refresh_devices))
        out_menu.add(rumps.separator)

        # BlackHole 찾기 (입력 고정)
        self.input_device = None
        
        for i, dev in enumerate(self.devices):
            if "BlackHole" in dev['name'] and dev['max_input_channels'] > 0:
                self.input_device = i
            
            if dev['max_output_channels'] > 0:
                if "BlackHole" not in dev['name']:
                    item = rumps.MenuItem(dev['name'], callback=self.select_output)
                    out_menu.add(item)
        
        if self.input_device is None:
             rumps.alert("오류", "BlackHole 2ch 드라이버를 찾을 수 없습니다. 설치를 확인해주세요.")

    def select_output(self, sender):
        for item in self.menu["출력 장치 선택"].values():
            if isinstance(item, rumps.MenuItem):
                item.state = False
        
        sender.state = True
        
        for i, dev in enumerate(self.devices):
            if dev['name'] == sender.title and dev['max_output_channels'] > 0:
                self.output_device = i
                break
        
        if self.is_running:
            self.stop_audio()
            self.start_audio()

    # --- 설정 변경 ---
    def set_threshold(self, db, item_title):
        self.threshold_db = db
        for item in self.menu["압축 강도 (Threshold)"].values():
            item.state = (item.title == item_title)

    def set_threshold_weak(self, sender): self.set_threshold(-10.0, sender.title)
    def set_threshold_normal(self, sender): self.set_threshold(-20.0, sender.title)
    def set_threshold_strong(self, sender): self.set_threshold(-30.0, sender.title)

    def set_gain(self, db, item_title):
        self.makeup_gain_db = db
        for item in self.menu["볼륨 증폭 (Gain)"].values():
            item.state = (item.title == item_title)

    def set_gain_low(self, sender): self.set_gain(0.0, sender.title)
    def set_gain_normal(self, sender): self.set_gain(10.0, sender.title)
    def set_gain_high(self, sender): self.set_gain(20.0, sender.title)

    # --- 실행 로직 ---
    def toggle_processing(self, sender):
        if self.is_running:
            self.stop_audio()
            sender.title = "야간 모드 시작"
            sender.state = False
        else:
            if self.output_device is None:
                rumps.alert("알림", "출력 장치를 먼저 선택해주세요!")
                return
            
            success = self.start_audio()
            if success:
                sender.title = "정지 (작동 중)"
                sender.state = True
                self.icon = resource_path("menu_icon_on.png")
                self.title = None

    def start_audio(self):
        try:
            if self.input_device is None: return False

            input_info = sd.query_devices(self.input_device, 'input')
            output_info = sd.query_devices(self.output_device, 'output')
            
            sr = int(output_info['default_samplerate'])
            channels = min(2, int(input_info['max_input_channels']), int(output_info['max_output_channels']))

            def callback(indata, outdata, frames, time, status):
                audio_data = indata.flatten()
                rms = np.sqrt(np.mean(audio_data**2))
                if rms <= 0: rms = 1e-9
                
                db = 20 * np.log10(rms)
                
                gain_reduction_db = 0.0
                if db > self.threshold_db:
                    overshoot = db - self.threshold_db
                    target = self.threshold_db + (overshoot / self.ratio)
                    gain_reduction_db = db - target
                
                total_gain_db = self.makeup_gain_db - gain_reduction_db
                linear_gain = 10 ** (total_gain_db / 20)
                
                processed = indata * linear_gain
                processed = np.clip(processed, -1.0, 1.0)
                outdata[:] = processed

            self.stream = sd.Stream(
                device=(self.input_device, self.output_device),
                channels=channels,
                samplerate=sr,
                blocksize=512,
                latency='low',
                callback=callback
            )
            self.stream.start()
            self.is_running = True
            return True
        except Exception as e:
            rumps.alert("오류 발생", str(e))
            self.is_running = False
            return False

    def stop_audio(self):
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        self.is_running = False
        self.title = None
        self.icon = resource_path("menu_icon.png")

if __name__ == "__main__":
    logging.info("Starting application...")
    try:
        NightModeApp().run()
    except Exception as e:
        logging.critical(f"Application crashed: {e}", exc_info=True)
