import logging

import numpy as np
import sounddevice as sd


class AudioRouter:
    def __init__(self, logger: logging.Logger):
        self.logger = logger
        self.stream = None
        self.current_output_name = None
        self.current_output_index = None
        self.threshold_db = -20.0
        self.makeup_gain_db = 10.0
        self.ratio = 4.0

    def configure(self, threshold_db: float, makeup_gain_db: float, ratio: float):
        self.threshold_db = threshold_db
        self.makeup_gain_db = makeup_gain_db
        self.ratio = ratio

    def find_blackhole_input(self) -> int | None:
        for index, device in enumerate(sd.query_devices()):
            if "BlackHole" in device["name"] and device["max_input_channels"] > 0:
                return index
        return None

    def start(self, output_index: int) -> bool:
        """sounddevice 인덱스를 직접 받아 스트림을 연다. 이름 매칭 없음."""
        input_index = self.find_blackhole_input()
        if input_index is None:
            self.logger.error("BlackHole 입력 장치를 찾을 수 없음")
            return False

        try:
            input_info = sd.query_devices(input_index, "input")
            output_info = sd.query_devices(output_index, "output")
            samplerate = int(output_info["default_samplerate"])
            channels = min(
                2,
                int(input_info["max_input_channels"]),
                int(output_info["max_output_channels"]),
            )
            output_name = output_info["name"]

            def callback(indata, outdata, _frames, _time, _status):
                rms = np.sqrt(np.mean(indata.flatten() ** 2))
                if rms <= 0:
                    rms = 1e-9

                current_db = 20 * np.log10(rms)
                gain_reduction_db = 0.0
                if current_db > self.threshold_db:
                    overshoot = current_db - self.threshold_db
                    target = self.threshold_db + (overshoot / self.ratio)
                    gain_reduction_db = current_db - target

                total_gain_db = self.makeup_gain_db - gain_reduction_db
                processed = indata * (10 ** (total_gain_db / 20))
                outdata[:] = np.clip(processed, -1.0, 1.0)

            self.stream = sd.Stream(
                device=(input_index, output_index),
                channels=channels,
                samplerate=samplerate,
                blocksize=512,
                latency="low",
                callback=callback,
            )
            self.stream.start()
            self.current_output_name = output_name
            self.current_output_index = output_index
            self.logger.info(
                f"오디오 스트림 시작: sd_index={output_index} name={output_name}"
            )
            return True
        except Exception as exc:
            self.logger.error(f"오디오 스트림 오류: {exc}")
            if self.stream is not None:
                try:
                    self.stream.close()
                except Exception:
                    self.logger.exception("실패한 오디오 스트림 정리 중 오류")
            self.stream = None
            self.current_output_name = None
            self.current_output_index = None
            return False

    def stop(self):
        if self.stream is not None:
            self.stream.stop()
            self.stream.close()
        self.stream = None
        self.current_output_name = None
        self.current_output_index = None

    def restart(self, output_index: int) -> bool:
        previous_stream = self.stream
        previous_output_name = self.current_output_name
        previous_output_index = self.current_output_index
        self.stop()
        if self.start(output_index):
            return True

        if previous_stream is not None and previous_output_index is not None:
            self.logger.debug(
                f"새 출력 전환 실패 - 기존 출력으로 복구 시도: "
                f"sd_index={previous_output_index} name={previous_output_name}"
            )
            return self.start(previous_output_index)

        return False
