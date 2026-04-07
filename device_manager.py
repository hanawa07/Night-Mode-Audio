import ctypes
from collections.abc import Callable
from dataclasses import dataclass

from PyObjCTools import AppHelper


CORE_AUDIO_PATH = "/System/Library/Frameworks/CoreAudio.framework/CoreAudio"
CORE_FOUNDATION_PATH = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"


def fourcc(code: str) -> int:
    return int.from_bytes(code.encode("ascii"), "big")


class AudioObjectPropertyAddress(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope", ctypes.c_uint32),
        ("mElement", ctypes.c_uint32),
    ]


AudioObjectPropertyListenerProc = ctypes.CFUNCTYPE(
    ctypes.c_int32,
    ctypes.c_uint32,
    ctypes.c_uint32,
    ctypes.POINTER(AudioObjectPropertyAddress),
    ctypes.c_void_p,
)


kAudioObjectSystemObject = 1
kAudioObjectPropertyScopeGlobal = fourcc("glob")
kAudioObjectPropertyScopeOutput = fourcc("outp")
kAudioObjectPropertyElementMain = 0
kAudioHardwarePropertyDevices = fourcc("dev#")
kAudioObjectPropertyName = fourcc("lnam")
kAudioObjectPropertyManufacturer = fourcc("lmak")
kAudioDevicePropertyDeviceUID = fourcc("uid ")
kAudioDevicePropertyTransportType = fourcc("tran")
kAudioDevicePropertyDeviceIsAlive = fourcc("livn")
kAudioDevicePropertyStreams = fourcc("stm#")

kAudioDeviceTransportTypeBuiltIn = fourcc("bltn")
kAudioDeviceTransportTypeVirtual = fourcc("virt")
kCFStringEncodingUTF8 = 0x08000100


@dataclass(slots=True)
class DeviceInfo:
    object_id: int
    uid: str
    name: str
    manufacturer: str
    transport_type: int
    is_alive: bool
    has_output: bool

    @property
    def is_virtual(self) -> bool:
        return self.transport_type == kAudioDeviceTransportTypeVirtual

    @property
    def is_builtin(self) -> bool:
        return self.transport_type == kAudioDeviceTransportTypeBuiltIn

    @property
    def display_name(self) -> str:
        if self.manufacturer and self.manufacturer not in self.name:
            return f"{self.name} ({self.manufacturer})"
        return self.name


class DeviceManager:
    def __init__(self, logger, on_change: Callable[[], None] | None = None):
        self.logger = logger
        self.on_change = on_change
        self.coreaudio = ctypes.cdll.LoadLibrary(CORE_AUDIO_PATH)
        self.corefoundation = ctypes.cdll.LoadLibrary(CORE_FOUNDATION_PATH)
        self._configure_ctypes()

        self.devices_by_uid: dict[str, DeviceInfo] = {}
        self.device_ids_by_uid: dict[str, int] = {}
        self._system_listener = None
        self._device_listener = None
        self._system_addresses: list[AudioObjectPropertyAddress] = []
        self._device_listener_addresses: dict[int, AudioObjectPropertyAddress] = {}

    def _configure_ctypes(self):
        self.coreaudio.AudioObjectGetPropertyDataSize.argtypes = [
            ctypes.c_uint32,
            ctypes.POINTER(AudioObjectPropertyAddress),
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint32),
        ]
        self.coreaudio.AudioObjectGetPropertyDataSize.restype = ctypes.c_int32
        self.coreaudio.AudioObjectGetPropertyData.argtypes = [
            ctypes.c_uint32,
            ctypes.POINTER(AudioObjectPropertyAddress),
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.c_void_p,
        ]
        self.coreaudio.AudioObjectGetPropertyData.restype = ctypes.c_int32
        self.coreaudio.AudioObjectAddPropertyListener.argtypes = [
            ctypes.c_uint32,
            ctypes.POINTER(AudioObjectPropertyAddress),
            AudioObjectPropertyListenerProc,
            ctypes.c_void_p,
        ]
        self.coreaudio.AudioObjectAddPropertyListener.restype = ctypes.c_int32
        self.coreaudio.AudioObjectRemovePropertyListener.argtypes = [
            ctypes.c_uint32,
            ctypes.POINTER(AudioObjectPropertyAddress),
            AudioObjectPropertyListenerProc,
            ctypes.c_void_p,
        ]
        self.coreaudio.AudioObjectRemovePropertyListener.restype = ctypes.c_int32

        self.corefoundation.CFStringGetCString.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_long,
            ctypes.c_uint32,
        ]
        self.corefoundation.CFStringGetCString.restype = ctypes.c_bool
        self.corefoundation.CFRelease.argtypes = [ctypes.c_void_p]
        self.corefoundation.CFRelease.restype = None

    def _address(self, selector: int, scope: int = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress:
        return AudioObjectPropertyAddress(selector, scope, kAudioObjectPropertyElementMain)

    def start(self):
        self._register_listeners()
        self.refresh()

    def stop(self):
        self._remove_listeners()

    def _register_listeners(self):
        def system_listener(_object_id, _num_addresses, _addresses, _client_data):
            AppHelper.callAfter(self._handle_coreaudio_event)
            return 0

        def device_listener(_object_id, _num_addresses, _addresses, _client_data):
            AppHelper.callAfter(self._handle_coreaudio_event)
            return 0

        self._system_listener = AudioObjectPropertyListenerProc(system_listener)
        self._device_listener = AudioObjectPropertyListenerProc(device_listener)
        self._system_addresses = [self._address(kAudioHardwarePropertyDevices)]

        for address in self._system_addresses:
            status = self.coreaudio.AudioObjectAddPropertyListener(
                kAudioObjectSystemObject,
                ctypes.byref(address),
                self._system_listener,
                None,
            )
            if status != 0:
                self.logger.error(f"Failed to add system CoreAudio listener {address.mSelector}: {status}")

    def _remove_listeners(self):
        if self._system_listener is not None:
            for address in self._system_addresses:
                self.coreaudio.AudioObjectRemovePropertyListener(
                    kAudioObjectSystemObject,
                    ctypes.byref(address),
                    self._system_listener,
                    None,
                )

        if self._device_listener is not None:
            for object_id, address in self._device_listener_addresses.items():
                self.coreaudio.AudioObjectRemovePropertyListener(
                    object_id,
                    ctypes.byref(address),
                    self._device_listener,
                    None,
                )

        self._device_listener_addresses.clear()

    def _sync_device_listeners(self, object_ids: list[int]):
        current_ids = set(self._device_listener_addresses.keys())
        new_ids = set(object_ids)

        for removed_id in current_ids - new_ids:
            address = self._device_listener_addresses.pop(removed_id)
            self.coreaudio.AudioObjectRemovePropertyListener(
                removed_id,
                ctypes.byref(address),
                self._device_listener,
                None,
            )

        for added_id in new_ids - current_ids:
            address = self._address(kAudioDevicePropertyDeviceIsAlive)
            status = self.coreaudio.AudioObjectAddPropertyListener(
                added_id,
                ctypes.byref(address),
                self._device_listener,
                None,
            )
            if status == 0:
                self._device_listener_addresses[added_id] = address
            else:
                self.logger.error(f"Failed to add device alive listener {added_id}: {status}")

    def _handle_coreaudio_event(self):
        self.refresh()
        if self.on_change is not None:
            self.on_change()

    def refresh(self):
        object_ids = self._get_device_ids()
        self._sync_device_listeners(object_ids)

        devices_by_uid: dict[str, DeviceInfo] = {}
        device_ids_by_uid: dict[str, int] = {}
        for object_id in object_ids:
            device = self._load_device(object_id)
            if device is None:
                continue
            devices_by_uid[device.uid] = device
            device_ids_by_uid[device.uid] = object_id

        self.devices_by_uid = devices_by_uid
        self.device_ids_by_uid = device_ids_by_uid

    def list_output_devices(self) -> list[DeviceInfo]:
        return sorted(
            [
                device
                for device in self.devices_by_uid.values()
                if device.has_output and device.is_alive and not device.is_virtual
            ],
            key=lambda device: (not device.is_builtin, device.display_name.lower()),
        )

    def get_device(self, uid: str | None) -> DeviceInfo | None:
        if uid is None:
            return None
        return self.devices_by_uid.get(uid)

    def get_builtin_output(self) -> DeviceInfo | None:
        for device in self.list_output_devices():
            if device.is_builtin:
                return device
        return None

    def _get_device_ids(self) -> list[int]:
        address = self._address(kAudioHardwarePropertyDevices)
        size = ctypes.c_uint32(0)
        status = self.coreaudio.AudioObjectGetPropertyDataSize(
            kAudioObjectSystemObject,
            ctypes.byref(address),
            0,
            None,
            ctypes.byref(size),
        )
        if status != 0 or size.value == 0:
            return []

        count = size.value // ctypes.sizeof(ctypes.c_uint32)
        buffer = (ctypes.c_uint32 * count)()
        io_size = ctypes.c_uint32(size.value)
        status = self.coreaudio.AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            ctypes.byref(address),
            0,
            None,
            ctypes.byref(io_size),
            ctypes.byref(buffer),
        )
        if status != 0:
            self.logger.error(f"Failed to read CoreAudio device list: {status}")
            return []

        return [int(buffer[idx]) for idx in range(count)]

    def _load_device(self, object_id: int) -> DeviceInfo | None:
        uid = self._get_cfstring(object_id, kAudioDevicePropertyDeviceUID)
        name = self._get_cfstring(object_id, kAudioObjectPropertyName)
        if not uid or not name:
            return None

        manufacturer = self._get_cfstring(object_id, kAudioObjectPropertyManufacturer) or ""
        transport_type = self._get_u32(object_id, kAudioDevicePropertyTransportType)
        is_alive = bool(self._get_u32(object_id, kAudioDevicePropertyDeviceIsAlive, default=1))
        has_output = self._has_output_streams(object_id)

        return DeviceInfo(
            object_id=object_id,
            uid=uid,
            name=name,
            manufacturer=manufacturer,
            transport_type=transport_type,
            is_alive=is_alive,
            has_output=has_output,
        )

    def _get_u32(self, object_id: int, selector: int, default: int = 0) -> int:
        address = self._address(selector)
        value = ctypes.c_uint32(0)
        size = ctypes.c_uint32(ctypes.sizeof(value))
        status = self.coreaudio.AudioObjectGetPropertyData(
            object_id,
            ctypes.byref(address),
            0,
            None,
            ctypes.byref(size),
            ctypes.byref(value),
        )
        if status != 0:
            return default
        return int(value.value)

    def _get_cfstring(self, object_id: int, selector: int) -> str | None:
        address = self._address(selector)
        value = ctypes.c_void_p()
        size = ctypes.c_uint32(ctypes.sizeof(value))
        status = self.coreaudio.AudioObjectGetPropertyData(
            object_id,
            ctypes.byref(address),
            0,
            None,
            ctypes.byref(size),
            ctypes.byref(value),
        )
        if status != 0 or not value.value:
            return None

        try:
            buffer = ctypes.create_string_buffer(1024)
            ok = self.corefoundation.CFStringGetCString(
                value,
                buffer,
                len(buffer),
                kCFStringEncodingUTF8,
            )
            if not ok:
                return None
            return buffer.value.decode("utf-8")
        finally:
            self.corefoundation.CFRelease(value)

    def _has_output_streams(self, object_id: int) -> bool:
        address = self._address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        size = ctypes.c_uint32(0)
        status = self.coreaudio.AudioObjectGetPropertyDataSize(
            object_id,
            ctypes.byref(address),
            0,
            None,
            ctypes.byref(size),
        )
        return status == 0 and size.value > 0
