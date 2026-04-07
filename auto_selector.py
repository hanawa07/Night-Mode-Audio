from collections import deque
from collections.abc import Iterable

from device_manager import DeviceInfo


class AutoSelector:
    def __init__(self, recent_connected: Iterable[str] | None = None, last_success_uid: str | None = None):
        self.recent_connected = deque(recent_connected or [], maxlen=10)
        self.last_success_uid = last_success_uid

    def export_state(self) -> tuple[list[str], str | None]:
        return list(self.recent_connected), self.last_success_uid

    def note_connected(self, uid: str):
        if uid in self.recent_connected:
            self.recent_connected.remove(uid)
        self.recent_connected.appendleft(uid)

    def note_success(self, uid: str | None):
        if uid is None:
            return
        self.last_success_uid = uid
        self.note_connected(uid)

    def remove_missing(self, available_uids: set[str]):
        self.recent_connected = deque(
            [uid for uid in self.recent_connected if uid in available_uids],
            maxlen=10,
        )
        if self.last_success_uid not in available_uids:
            self.last_success_uid = None

    def update_devices(self, devices: list[DeviceInfo], previous_uids: set[str]) -> set[str]:
        available_uids = {device.uid for device in devices}
        if previous_uids:
            new_uids = available_uids - previous_uids
            for uid in new_uids:
                self.note_connected(uid)
        self.remove_missing(available_uids)
        return available_uids

    def select(self, devices: list[DeviceInfo]) -> DeviceInfo | None:
        if not devices:
            return None

        devices_by_uid = {device.uid: device for device in devices}

        for uid in self.recent_connected:
            device = devices_by_uid.get(uid)
            if device is not None:
                return device

        if self.last_success_uid is not None:
            device = devices_by_uid.get(self.last_success_uid)
            if device is not None:
                return device

        for device in devices:
            if device.is_builtin:
                return device

        return devices[0]
