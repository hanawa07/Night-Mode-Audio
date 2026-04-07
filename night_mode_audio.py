import rumps
import sounddevice as sd
import numpy as np
import threading
import time
import sys
import os
import logging
import plistlib
import json
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
DEFAULT_OUTPUT_LABEL = "시스템 기본 출력 장치"
OUTPUT_MODE_AUTO = "auto"
OUTPUT_MODE_MANUAL = "manual"

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
        
        # 기본 설정값 (로드 실패 시 사용)
        self.threshold_db = -20.0
        self.makeup_gain_db = 10.0
        self.ratio = 4.0
        self.saved_device_name = None
        self.last_physical_output_name = None
        self.should_auto_start_processing = False
        self.selected_output_name = None
        self.default_output_item = None
        self.output_mode = OUTPUT_MODE_AUTO
        self.last_resolved_output_device = None
        self.default_output_watcher = None

        # 설정 로드
        self.load_config()
        
        self.build_menu()
        self.refresh_devices(None)
        
        # 자동 실행 플래시 동기화 (Launch Agent)
        self.menu["설정"]["로그인 시 자동 실행"].state = self.is_auto_start_enabled()
        
        # 저장된 설정에 따라 야간 모드 자동 시작
        if self.should_auto_start_processing and self.get_selected_output_index() is not None:
            logging.info("Auto-starting processing based on saved config")
            self.toggle_processing(self.menu["야간 모드 시작"])


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

            output_mode_menu = rumps.MenuItem("출력 장치 모드")
            output_mode_menu.add(rumps.MenuItem("자동", callback=self.set_output_mode_auto))
            output_mode_menu.add(rumps.MenuItem("수동", callback=self.set_output_mode_manual))
            
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
                output_mode_menu,
                output_menu,
                settings_menu,
                rumps.separator,
                rumps.MenuItem("종료", callback=rumps.quit_application)
            ]
            
            # 초기 체크 설정 (메모리 값 기반)
            t_map = {-10.0: "약하게 (-10dB)", -20.0: "보통 (-20dB)", -30.0: "강하게 (-30dB)"}
            g_map = {0.0: "낮게 (0dB)", 10.0: "보통 (+10dB)", 20.0: "높게 (+20dB)"}
            
            if self.threshold_db in t_map:
                self.menu["압축 강도 (Threshold)"][t_map[self.threshold_db]].state = True
            else:
                self.menu["압축 강도 (Threshold)"]["보통 (-20dB)"].state = True
                
            if self.makeup_gain_db in g_map:
                self.menu["볼륨 증폭 (Gain)"][g_map[self.makeup_gain_db]].state = True
            else:
                self.menu["볼륨 증폭 (Gain)"]["보통 (+10dB)"].state = True

            self.menu["출력 장치 모드"]["자동"].state = (self.output_mode == OUTPUT_MODE_AUTO)
            self.menu["출력 장치 모드"]["수동"].state = (self.output_mode == OUTPUT_MODE_MANUAL)
                
            logging.info("Menu built successfully")
        except Exception as e:
            logging.error(f"Menu build failed: {e}")
            raise e

    # --- 설정 파일 관리 (JSON) ---
    def get_config_path(self):
        return Path.home() / ".night_mode_config.json"

    def load_config(self):
        config_path = self.get_config_path()
        if config_path.exists():
            try:
                with open(config_path, 'r') as f:
                    config = json.load(f)
                    self.saved_device_name = config.get("output_device_name")
                    self.last_physical_output_name = config.get("last_physical_output_name")
                    self.should_auto_start_processing = config.get("is_running", False)
                    self.threshold_db = config.get("threshold_db", -20.0)
                    self.makeup_gain_db = config.get("makeup_gain_db", 10.0)
                    self.output_mode = config.get("output_mode", OUTPUT_MODE_AUTO)
                logging.info(f"Config loaded: {config}")
            except Exception as e:
                logging.error(f"Failed to load config: {e}")

    def save_config(self):
        try:
            current_device_name = self.selected_output_name
            if (
                current_device_name is None
                and self.output_device is not None
                and self.output_device < len(self.devices)
            ):
                current_device_name = self.devices[self.output_device]['name']

            config = {
                "output_device_name": current_device_name or self.saved_device_name,
                "last_physical_output_name": self.last_physical_output_name,
                "is_running": self.is_running,
                "threshold_db": self.threshold_db,
                "makeup_gain_db": self.makeup_gain_db,
                "output_mode": self.output_mode
            }
            with open(self.get_config_path(), 'w') as f:
                json.dump(config, f)
            logging.debug(f"Config saved: {config}")
        except Exception as e:
            logging.error(f"Failed to save config: {e}")

    # --- 자동 실행 관리 (Launch Agent) ---
    def get_plist_path(self):
        return Path.home() / "Library" / "LaunchAgents" / "com.lizstudio.nightmodeaudio.plist"

    def is_auto_start_enabled(self):
        return self.get_plist_path().exists()

    def toggle_auto_start(self, sender):
        plist_path = self.get_plist_path()
        if sender.state:
            if plist_path.exists():
                plist_path.unlink()
            sender.state = False
            logging.info("Auto-start disabled")
        else:
            try:
                if getattr(sys, 'frozen', False):
                    executable_path = sys.executable
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
    def get_default_output_index(self):
        try:
            default_output_info = sd.query_devices(kind='output')
            all_devices = sd.query_devices()
        except Exception as e:
            logging.error(f"Failed to read default output device: {e}")
            return None

        for i, dev in enumerate(all_devices):
            if (
                dev['name'] == default_output_info['name']
                and dev['hostapi'] == default_output_info['hostapi']
                and dev['max_output_channels'] > 0
            ):
                return i

        logging.error(f"Failed to resolve default output device index: {default_output_info}")
        return None

    def is_blackhole_device(self, device_index):
        if device_index is None or device_index < 0 or device_index >= len(self.devices):
            return False
        return "BlackHole" in self.devices[device_index]["name"]

    def find_output_device_by_name(self, device_name):
        if not device_name:
            return None

        for i, dev in enumerate(self.devices):
            if dev["name"] == device_name and dev["max_output_channels"] > 0 and "BlackHole" not in dev["name"]:
                return i
        return None

    def get_safe_auto_output_index(self):
        default_output = self.get_default_output_index()
        if default_output is None:
            fallback_output = self.find_output_device_by_name(self.last_physical_output_name)
            if fallback_output is not None:
                return fallback_output
            return None

        if not self.is_blackhole_device(default_output):
            return default_output

        fallback_output = self.find_output_device_by_name(self.last_physical_output_name)
        if fallback_output is not None:
            logging.info(
                f"Auto mode ignored BlackHole default output; using last physical output {fallback_output}"
            )
            return fallback_output

        if self.output_device is not None and not self.is_blackhole_device(self.output_device):
            logging.info(
                f"Auto mode ignored BlackHole default output; keeping current physical output {self.output_device}"
            )
            return self.output_device

        logging.warning("Auto mode found BlackHole as default output and no fallback physical output is available")
        return None

    def sync_processing_ui(self):
        toggle_item = self.menu["야간 모드 시작"]
        if self.is_running:
            toggle_item.title = "정지 (작동 중)"
            toggle_item.state = True
            self.icon = resource_path("menu_icon_on.png")
        else:
            toggle_item.title = "야간 모드 시작"
            toggle_item.state = False
            self.icon = resource_path("menu_icon.png")
        self.title = None

    def get_selected_output_index(self):
        if self.output_mode == OUTPUT_MODE_AUTO:
            return self.get_safe_auto_output_index()
        if self.selected_output_name == DEFAULT_OUTPUT_LABEL:
            return self.get_safe_auto_output_index()
        return self.output_device

    def update_selected_output_label(self):
        if self.default_output_item is None:
            return

        default_index = self.get_default_output_index()
        if default_index is None or default_index >= len(self.devices):
            if self.output_mode == OUTPUT_MODE_AUTO:
                self.default_output_item.title = f"{DEFAULT_OUTPUT_LABEL} (자동)"
            else:
                self.default_output_item.title = DEFAULT_OUTPUT_LABEL
            return

        default_name = self.devices[default_index]["name"]
        if self.output_mode == OUTPUT_MODE_AUTO:
            if self.is_blackhole_device(default_index):
                if self.last_physical_output_name:
                    self.default_output_item.title = (
                        f"{DEFAULT_OUTPUT_LABEL} (자동: {self.last_physical_output_name}, 기본={default_name})"
                    )
                else:
                    self.default_output_item.title = f"{DEFAULT_OUTPUT_LABEL} (자동 불가: {default_name})"
            else:
                self.default_output_item.title = f"{DEFAULT_OUTPUT_LABEL} (자동: {default_name})"
        else:
            self.default_output_item.title = f"{DEFAULT_OUTPUT_LABEL} ({default_name})"

    def set_output_mode(self, mode):
        self.output_mode = mode
        self.menu["출력 장치 모드"]["자동"].state = (mode == OUTPUT_MODE_AUTO)
        self.menu["출력 장치 모드"]["수동"].state = (mode == OUTPUT_MODE_MANUAL)
        if mode == OUTPUT_MODE_AUTO:
            self.selected_output_name = DEFAULT_OUTPUT_LABEL
            self.saved_device_name = DEFAULT_OUTPUT_LABEL
            resolved_output = self.get_safe_auto_output_index()
            if resolved_output is not None:
                self.output_device = resolved_output
            if self.default_output_item is not None:
                for item in self.menu["출력 장치 선택"].values():
                    if isinstance(item, rumps.MenuItem):
                        item.state = False
                self.default_output_item.state = True
            self.update_selected_output_label()
            if resolved_output is None:
                rumps.alert(
                    "알림",
                    "자동 모드는 기본 출력이 BlackHole일 때 바로 사용할 수 없습니다. "
                    "실제 스피커/이어폰을 수동으로 선택해 주세요."
                )
        self.save_config()
        if self.is_running:
            self.stop_audio()
            if self.get_selected_output_index() is not None:
                self.start_audio()
            self.sync_processing_ui()

    def set_output_mode_auto(self, _):
        self.set_output_mode(OUTPUT_MODE_AUTO)

    def set_output_mode_manual(self, _):
        self.set_output_mode(OUTPUT_MODE_MANUAL)

    def watch_default_output(self, _):
        if self.output_mode != OUTPUT_MODE_AUTO:
            return

        self.devices = sd.query_devices()
        current_output = self.get_default_output_index()
        if current_output is None:
            return

        if self.default_output_item is not None:
            self.update_selected_output_label()

        resolved_output = self.get_safe_auto_output_index()
        if resolved_output is None:
            if self.is_running:
                logging.warning("Auto mode has no safe physical output; keeping current stream")
            return

        if self.last_resolved_output_device == resolved_output:
            return

        logging.info(f"Default output changed: {self.last_resolved_output_device} -> {resolved_output}")
        self.output_device = resolved_output
        self.last_resolved_output_device = resolved_output

        if self.is_running:
            self.stop_audio()
            success = self.start_audio()
            if not success:
                logging.error("Failed to restart audio after default output change")
            self.sync_processing_ui()

    def refresh_devices(self, _):
        self.devices = sd.query_devices()
        out_menu = self.menu["출력 장치 선택"]
        out_menu.clear()
        out_menu.add(rumps.MenuItem("목록 새로고침", callback=self.refresh_devices))
        out_menu.add(rumps.separator)
        self.default_output_item = rumps.MenuItem(DEFAULT_OUTPUT_LABEL, callback=self.select_output)
        out_menu.add(self.default_output_item)
        out_menu.add(rumps.separator)

        self.input_device = None
        self.output_device = None
        self.selected_output_name = None
        
        for i, dev in enumerate(self.devices):
            if "BlackHole" in dev['name'] and dev['max_input_channels'] > 0:
                self.input_device = i
            
            if dev['max_output_channels'] > 0:
                if "BlackHole" not in dev['name']:
                    item = rumps.MenuItem(dev['name'], callback=self.select_output)
                    # 저장된 장치 이름과 일치하면 자동 선택
                    if self.saved_device_name and dev['name'] == self.saved_device_name:
                        item.state = True
                        self.output_device = i
                        self.selected_output_name = dev['name']
                        logging.info(f"Auto-selected saved device: {dev['name']}")
                    out_menu.add(item)

        if self.saved_device_name == DEFAULT_OUTPUT_LABEL:
            self.default_output_item.state = True
            self.selected_output_name = DEFAULT_OUTPUT_LABEL

        if self.output_mode == OUTPUT_MODE_AUTO or self.selected_output_name is None:
            self.default_output_item.state = True
            self.selected_output_name = DEFAULT_OUTPUT_LABEL
            self.saved_device_name = DEFAULT_OUTPUT_LABEL
            resolved_output = self.get_safe_auto_output_index()
            if resolved_output is not None:
                self.output_device = resolved_output

        self.update_selected_output_label()
        
        if self.input_device is None:
             rumps.alert("오류", "BlackHole 2ch 드라이버를 찾을 수 없습니다. 설치를 확인해주세요.")

    def select_output(self, sender):
        for item in self.menu["출력 장치 선택"].values():
            if isinstance(item, rumps.MenuItem):
                item.state = False
        
        sender.state = True

        selected_title = sender.title
        if selected_title.startswith(DEFAULT_OUTPUT_LABEL):
            self.output_mode = OUTPUT_MODE_AUTO
            self.menu["출력 장치 모드"]["자동"].state = True
            self.menu["출력 장치 모드"]["수동"].state = False
            self.selected_output_name = DEFAULT_OUTPUT_LABEL
            self.saved_device_name = DEFAULT_OUTPUT_LABEL
            resolved_output = self.get_safe_auto_output_index()
            if resolved_output is not None:
                self.output_device = resolved_output
            self.update_selected_output_label()
            self.save_config()
            if self.is_running:
                self.stop_audio()
                if self.get_selected_output_index() is not None:
                    self.start_audio()
                self.sync_processing_ui()
            return
        
        for i, dev in enumerate(self.devices):
            if dev['name'] == sender.title and dev['max_output_channels'] > 0:
                self.output_mode = OUTPUT_MODE_MANUAL
                self.menu["출력 장치 모드"]["자동"].state = False
                self.menu["출력 장치 모드"]["수동"].state = True
                self.output_device = i
                self.selected_output_name = dev['name']
                self.saved_device_name = dev['name']
                self.last_physical_output_name = dev['name']
                self.save_config()
                break
        
        if self.is_running:
            self.stop_audio()
            self.start_audio()

    # --- 설정 변경 ---
    def set_threshold(self, db, item_title):
        self.threshold_db = db
        for item in self.menu["압축 강도 (Threshold)"].values():
            item.state = (item.title == item_title)
        self.save_config()

    def set_threshold_weak(self, sender): self.set_threshold(-10.0, sender.title)
    def set_threshold_normal(self, sender): self.set_threshold(-20.0, sender.title)
    def set_threshold_strong(self, sender): self.set_threshold(-30.0, sender.title)

    def set_gain(self, db, item_title):
        self.makeup_gain_db = db
        for item in self.menu["볼륨 증폭 (Gain)"].values():
            item.state = (item.title == item_title)
        self.save_config()

    def set_gain_low(self, sender): self.set_gain(0.0, sender.title)
    def set_gain_normal(self, sender): self.set_gain(10.0, sender.title)
    def set_gain_high(self, sender): self.set_gain(20.0, sender.title)

    # --- 실행 로직 ---
    def toggle_processing(self, sender):
        if self.is_running:
            self.stop_audio()
        else:
            if self.get_selected_output_index() is None:
                if not self.should_auto_start_processing: # 자동 시작 중이 아닐 때만 경고
                    rumps.alert("알림", "출력 장치를 먼저 선택해주세요!")
                return
            
            self.start_audio()
        
        self.sync_processing_ui()
        
        self.save_config()

    def start_audio(self):
        try:
            if self.input_device is None: return False

            input_info = sd.query_devices(self.input_device, 'input')
            selected_output = self.get_selected_output_index()
            if selected_output is None:
                logging.error("No output device selected or default output unavailable")
                return False

            output_info = sd.query_devices(selected_output, 'output')
            
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
                device=(self.input_device, selected_output),
                channels=channels,
                samplerate=sr,
                blocksize=512,
                latency='low',
                callback=callback
            )
            self.stream.start()
            self.output_device = selected_output
            self.last_resolved_output_device = selected_output
            if not self.is_blackhole_device(selected_output):
                self.last_physical_output_name = self.devices[selected_output]["name"]
            self.update_selected_output_label()
            self.is_running = True
            return True
        except Exception as e:
            logging.error(f"Audio stream error: {e}")
            self.is_running = False
            self.stream = None
            return False

    def stop_audio(self):
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        self.is_running = False
        self.sync_processing_ui()

if __name__ == "__main__":
    logging.info("Starting application...")
    try:
        app = NightModeApp()
        app.default_output_watcher = rumps.Timer(app.watch_default_output, 2)
        app.default_output_watcher.start()
        app.run()
    except Exception as e:
        logging.critical(f"Application crashed: {e}", exc_info=True)
