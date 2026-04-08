import json
import logging
import os
import plistlib
import sys
from pathlib import Path

import rumps
from PyObjCTools import AppHelper

from audio_router import AudioRouter
from auto_selector import AutoSelector
from device_manager import DeviceManager


def resource_path(relative_path: str) -> str:
    if hasattr(sys, "_MEIPASS"):
        return os.path.join(sys._MEIPASS, relative_path)

    if getattr(sys, "frozen", False):
        base_path = os.path.dirname(sys.executable)

        path = os.path.join(base_path, relative_path)
        if os.path.exists(path):
            return path

        path = os.path.join(base_path, "..", "Resources", relative_path)
        if os.path.exists(path):
            return path

    return os.path.join(os.path.abspath("."), relative_path)


APP_NAME = "Night Mode"
AUTO_OUTPUT_LABEL = "자동 출력 장치"
OUTPUT_MODE_AUTO = "auto"
OUTPUT_MODE_MANUAL = "manual"

log_file = os.path.expanduser("~/night_mode_debug.log")
logging.basicConfig(
    filename=log_file,
    level=logging.DEBUG,
    format="%(asctime)s - %(levelname)s - %(message)s",
)


class NightModeApp(rumps.App):
    def __init__(self):
        super().__init__(APP_NAME, icon=resource_path("menu_icon.png"), quit_button=None)
        logging.info("Rumps init successful")

        self.threshold_db = -20.0
        self.makeup_gain_db = 10.0
        self.ratio = 4.0
        self.output_mode = OUTPUT_MODE_AUTO
        self.manual_output_uid = None
        self.should_auto_start_processing = False
        self.is_running = False
        self.current_output_uid = None
        self.output_menu_items = {}
        self.previous_auto_uids = set()
        self._startup_timer = None

        self.load_config()
        logging.info(f"Config loaded: {self.config_data}")

        recent_connected = self.config_data.get("physical_output_history", [])
        last_success_uid = self.config_data.get("last_success_uid")
        self.auto_selector = AutoSelector(recent_connected=recent_connected, last_success_uid=last_success_uid)
        self.audio_router = AudioRouter(logging.getLogger(__name__))
        self.audio_router.configure(self.threshold_db, self.makeup_gain_db, self.ratio)
        self.device_manager = DeviceManager(logging.getLogger(__name__), on_change=self.handle_devices_changed)

        self.build_menu()
        logging.info("Menu built successfully")
        self.device_manager.start()
        logging.info("Device manager started")
        self.handle_devices_changed()
        logging.info("Initial device sync completed")

        self.menu["설정"]["로그인 시 자동 실행"].state = self.is_auto_start_enabled()

        if self.should_auto_start_processing:
            logging.info("Scheduling deferred auto-start")
            self._startup_timer = rumps.Timer(self._deferred_auto_start_timer, 0.5)
            self._startup_timer.start()

    def _deferred_auto_start_timer(self, _sender):
        if self._startup_timer is not None:
            self._startup_timer.stop()
            self._startup_timer = None
        self.defer_auto_start()

    def defer_auto_start(self):
        logging.info("Deferred auto-start fired")
        self.start_processing()

    @property
    def config_data(self):
        return getattr(self, "_config_data", {})

    def build_menu(self):
        toggle_item = rumps.MenuItem("야간 모드 시작", callback=self.toggle_processing)

        threshold_menu = rumps.MenuItem("압축 강도 (Threshold)")
        threshold_menu.add(rumps.MenuItem("약하게 (-10dB)", callback=self.set_threshold_weak))
        threshold_menu.add(rumps.MenuItem("보통 (-20dB)", callback=self.set_threshold_normal))
        threshold_menu.add(rumps.MenuItem("강하게 (-30dB)", callback=self.set_threshold_strong))

        gain_menu = rumps.MenuItem("볼륨 증폭 (Gain)")
        gain_menu.add(rumps.MenuItem("낮게 (0dB)", callback=self.set_gain_low))
        gain_menu.add(rumps.MenuItem("보통 (+10dB)", callback=self.set_gain_normal))
        gain_menu.add(rumps.MenuItem("높게 (+20dB)", callback=self.set_gain_high))

        mode_menu = rumps.MenuItem("출력 장치 모드")
        mode_menu.add(rumps.MenuItem("자동", callback=self.set_output_mode_auto))
        mode_menu.add(rumps.MenuItem("수동", callback=self.set_output_mode_manual))

        output_menu = rumps.MenuItem("출력 장치 선택")
        output_menu.add(rumps.MenuItem(AUTO_OUTPUT_LABEL, callback=self.select_auto_output))
        output_menu.add(rumps.separator)
        output_menu.add(rumps.MenuItem("목록 새로고침", callback=self.manual_refresh_devices))
        output_menu.add(rumps.separator)

        settings_menu = rumps.MenuItem("설정")
        settings_menu.add(rumps.MenuItem("로그인 시 자동 실행", callback=self.toggle_auto_start))

        self.menu = [
            toggle_item,
            rumps.separator,
            threshold_menu,
            gain_menu,
            rumps.separator,
            mode_menu,
            output_menu,
            settings_menu,
            rumps.separator,
            rumps.MenuItem("종료", callback=self.quit_app),
        ]

        self.menu["출력 장치 모드"]["자동"].state = self.output_mode == OUTPUT_MODE_AUTO
        self.menu["출력 장치 모드"]["수동"].state = self.output_mode == OUTPUT_MODE_MANUAL

        threshold_title = {-10.0: "약하게 (-10dB)", -20.0: "보통 (-20dB)", -30.0: "강하게 (-30dB)"}.get(
            self.threshold_db,
            "보통 (-20dB)",
        )
        gain_title = {0.0: "낮게 (0dB)", 10.0: "보통 (+10dB)", 20.0: "높게 (+20dB)"}.get(
            self.makeup_gain_db,
            "보통 (+10dB)",
        )
        self.menu["압축 강도 (Threshold)"][threshold_title].state = True
        self.menu["볼륨 증폭 (Gain)"][gain_title].state = True

    def get_config_path(self) -> Path:
        return Path.home() / ".night_mode_config.json"

    def load_config(self):
        self._config_data = {}
        config_path = self.get_config_path()
        if not config_path.exists():
            return

        try:
            with open(config_path, "r") as handle:
                self._config_data = json.load(handle)
        except Exception as exc:
            logging.error(f"Failed to load config: {exc}")
            return

        self.manual_output_uid = self.config_data.get("manual_output_uid")
        self.output_mode = self.config_data.get("output_mode", OUTPUT_MODE_AUTO)
        self.should_auto_start_processing = self.config_data.get("is_running", False)
        self.threshold_db = self.config_data.get("threshold_db", -20.0)
        self.makeup_gain_db = self.config_data.get("makeup_gain_db", 10.0)

    def save_config(self):
        recent_connected, last_success_uid = self.auto_selector.export_state()
        config = {
            "manual_output_uid": self.manual_output_uid,
            "output_mode": self.output_mode,
            "is_running": self.is_running,
            "threshold_db": self.threshold_db,
            "makeup_gain_db": self.makeup_gain_db,
            "physical_output_history": recent_connected,
            "last_success_uid": last_success_uid,
        }
        with open(self.get_config_path(), "w") as handle:
            json.dump(config, handle)
        self._config_data = config
        logging.debug(f"Config saved: {config}")

    def get_plist_path(self) -> Path:
        return Path.home() / "Library" / "LaunchAgents" / "com.lizstudio.nightmodeaudio.plist"

    def is_auto_start_enabled(self) -> bool:
        return self.get_plist_path().exists()

    def toggle_auto_start(self, sender):
        plist_path = self.get_plist_path()
        if sender.state:
            if plist_path.exists():
                plist_path.unlink()
            sender.state = False
            return

        try:
            if getattr(sys, "frozen", False):
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
                "ProcessType": "Interactive",
            }

            plist_path.parent.mkdir(parents=True, exist_ok=True)
            with open(plist_path, "wb") as handle:
                plistlib.dump(plist_data, handle)
            sender.state = True
        except Exception as exc:
            logging.error(f"Failed to enable auto-start: {exc}")
            rumps.alert("오류", f"자동 실행 설정에 실패했습니다: {exc}")

    def handle_devices_changed(self):
        devices = self.device_manager.list_output_devices()
        current_auto_uids = self.auto_selector.update_devices(devices, self.previous_auto_uids)
        self.previous_auto_uids = current_auto_uids

        self.refresh_output_menu(devices)

        if self.output_mode == OUTPUT_MODE_AUTO and self.is_running:
            target = self.resolve_target_device()
            if target is None:
                self.stop_processing()
            elif target.uid != self.current_output_uid:
                self.start_processing(restart=True)

        if self.output_mode == OUTPUT_MODE_MANUAL and self.is_running:
            manual_device = self.device_manager.get_device(self.manual_output_uid)
            if manual_device is None:
                self.stop_processing()

    def manual_refresh_devices(self, _):
        self.device_manager.refresh()
        self.handle_devices_changed()

    def make_unique_label(self, base_label: str) -> str:
        label = base_label
        counter = 2
        while label in self.output_menu_items:
            label = f"{base_label} ({counter})"
            counter += 1
        return label

    def refresh_output_menu(self, devices):
        output_menu = self.menu["출력 장치 선택"]
        output_menu.clear()
        auto_label = AUTO_OUTPUT_LABEL
        auto_device = self.resolve_auto_device()
        if auto_device is not None:
            auto_label = f"{AUTO_OUTPUT_LABEL} ({auto_device.display_name})"

        auto_item = rumps.MenuItem(auto_label, callback=self.select_auto_output)
        auto_item.state = self.output_mode == OUTPUT_MODE_AUTO
        output_menu.add(auto_item)
        output_menu.add(rumps.separator)
        output_menu.add(rumps.MenuItem("목록 새로고침", callback=self.manual_refresh_devices))
        output_menu.add(rumps.separator)

        self.output_menu_items = {}
        for device in devices:
            label = self.make_unique_label(device.display_name)
            item = rumps.MenuItem(label, callback=self.select_manual_output)
            item.output_uid = device.uid
            item.state = self.output_mode == OUTPUT_MODE_MANUAL and self.manual_output_uid == device.uid
            self.output_menu_items[label] = item
            output_menu.add(item)

    def resolve_auto_device(self):
        return self.auto_selector.select(self.device_manager.list_output_devices())

    def resolve_target_device(self):
        if self.output_mode == OUTPUT_MODE_AUTO:
            return self.resolve_auto_device()
        return self.device_manager.get_device(self.manual_output_uid)

    def start_processing(self, restart: bool = False) -> bool:
        logging.info(f"start_processing called restart={restart} is_running={self.is_running} mode={self.output_mode}")
        try:
            return self._start_processing_inner(restart)
        except Exception:
            logging.exception("start_processing 예외 발생")
            self.stop_processing()
            return False

    def _start_processing_inner(self, restart: bool) -> bool:
        target = self.resolve_target_device()
        if target is None:
            logging.error("No target device resolved")
            rumps.alert("알림", "사용 가능한 출력 장치가 없습니다.")
            self.stop_processing()
            return False

        # UID → sounddevice 인덱스 변환
        sd_index = self.device_manager.get_sd_index(target.uid)
        if sd_index is None:
            # PortAudio는 Pa_Initialize() 시점의 장치 목록을 고정함.
            # Bluetooth 장치 등 이후 연결된 장치는 재초기화 후에만 보임.
            logging.debug(f"'{target.name}' sounddevice 미발견 - PortAudio 재초기화 시도")
            self.audio_router.stop()  # 재초기화 전 스트림 반드시 중단
            import sounddevice as sd
            try:
                sd._terminate()
                sd._initialize()
                logging.debug("PortAudio 재초기화 완료")
            except Exception:
                logging.exception("PortAudio 재초기화 실패")
                self.stop_processing()
                return False
            sd_index = self.device_manager.get_sd_index(target.uid)

        if sd_index is None:
            logging.error(
                f"UID를 sounddevice 인덱스로 변환 실패: uid={target.uid} name={target.name}"
            )
            self.stop_processing()
            return False

        self.audio_router.configure(self.threshold_db, self.makeup_gain_db, self.ratio)
        success = (
            self.audio_router.restart(sd_index)
            if restart or self.is_running
            else self.audio_router.start(sd_index)
        )
        if not success:
            self.stop_processing()
            return False

        self.is_running = True
        self.current_output_uid = target.uid
        self.auto_selector.note_success(target.uid)
        self.sync_processing_ui()
        self.save_config()
        logging.info(f"처리 시작: uid={target.uid} name={target.name} sd_index={sd_index}")
        return True

    def stop_processing(self):
        self.audio_router.stop()
        self.is_running = False
        self.current_output_uid = None
        self.sync_processing_ui()
        self.save_config()

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

    def toggle_processing(self, _):
        if self.is_running:
            self.stop_processing()
        else:
            self.start_processing()

    def set_output_mode(self, mode: str):
        self.output_mode = mode
        self.menu["출력 장치 모드"]["자동"].state = mode == OUTPUT_MODE_AUTO
        self.menu["출력 장치 모드"]["수동"].state = mode == OUTPUT_MODE_MANUAL
        self.refresh_output_menu(self.device_manager.list_output_devices())
        if self.is_running:
            self.start_processing(restart=True)
        self.save_config()

    def set_output_mode_auto(self, _):
        self.set_output_mode(OUTPUT_MODE_AUTO)

    def set_output_mode_manual(self, _):
        self.set_output_mode(OUTPUT_MODE_MANUAL)

    def select_auto_output(self, _):
        self.set_output_mode(OUTPUT_MODE_AUTO)

    def select_manual_output(self, sender):
        self.manual_output_uid = getattr(sender, "output_uid", None)
        self.output_mode = OUTPUT_MODE_MANUAL
        self.menu["출력 장치 모드"]["자동"].state = False
        self.menu["출력 장치 모드"]["수동"].state = True
        self.refresh_output_menu(self.device_manager.list_output_devices())
        if self.is_running:
            self.start_processing(restart=True)
        self.save_config()

    def set_threshold(self, db: float, item_title: str):
        self.threshold_db = db
        for item in self.menu["압축 강도 (Threshold)"].values():
            item.state = item.title == item_title
        self.audio_router.configure(self.threshold_db, self.makeup_gain_db, self.ratio)
        self.save_config()

    def set_gain(self, db: float, item_title: str):
        self.makeup_gain_db = db
        for item in self.menu["볼륨 증폭 (Gain)"].values():
            item.state = item.title == item_title
        self.audio_router.configure(self.threshold_db, self.makeup_gain_db, self.ratio)
        self.save_config()

    def set_threshold_weak(self, sender):
        self.set_threshold(-10.0, sender.title)

    def set_threshold_normal(self, sender):
        self.set_threshold(-20.0, sender.title)

    def set_threshold_strong(self, sender):
        self.set_threshold(-30.0, sender.title)

    def set_gain_low(self, sender):
        self.set_gain(0.0, sender.title)

    def set_gain_normal(self, sender):
        self.set_gain(10.0, sender.title)

    def set_gain_high(self, sender):
        self.set_gain(20.0, sender.title)

    def quit_app(self, _):
        self.audio_router.stop()
        self.device_manager.stop()
        rumps.quit_application()


if __name__ == "__main__":
    logging.info("Starting application...")
    app = NightModeApp()
    app.run()
