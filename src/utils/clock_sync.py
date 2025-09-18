# -*- coding: utf-8 -*-
# 将数据局部时间，也就是记录数据的设备时间对齐LSL时间
"""
Libs/clock_sync.py
设备时钟（手机坐标）→ 主机时钟（LSL 坐标）的偏移估计与映射。
策略：EWMA 平滑 + 单次更新夹持，避免爆跳；按设备维度维护独立 offset。
"""

from typing import Optional, Dict
from pylsl import local_clock
from logger import logger


class _OffsetEWMA:
    def __init__(self, alpha: float, clamp_s: float):
        self.alpha = float(alpha)
        self.clamp = float(clamp_s)
        self.inited = False
        self.offset = 0.0

    def update(self, sample_offset: float) -> float:
        # 夹持，防一次性大跳影响整体
        if self.inited:
            delta = sample_offset - self.offset
            if abs(delta) > self.clamp:
                logger.warning("[ClockSync] clamp delta=%.3f -> clamp=%.3f (sample_offset=%.6f, prev=%.6f)",
                   delta, self.clamp, sample_offset, self.offset)
                sample_offset = self.offset + (self.clamp if delta > 0 else -self.clamp)
            self.offset = (1 - self.alpha) * self.offset + self.alpha * sample_offset

        else:
            self.offset = sample_offset
            self.inited = True

            logger.info(f"[ClockSync] init offset={self.offset:.6f}")

        return self.offset

    def estimate(self) -> float:
        return self.offset if self.inited else 0.0


class ClockSync:
    """
    host_ts = map_event_ts(device, t_device, te, ts_arrival)
    - device: 设备标识（用来拆分多设备的 offset）
    - t_device: 手机坐标的包到达时间（秒，Double）
    - te: 手机坐标的“事件时间”（秒，Double）
    - ts_arrival: 本机收到样本的时间（local_clock 坐标）
    返回：事件在主机坐标系的时间戳
    """
    def __init__(self, alpha: float = 0.05, clamp_s: float = 1.0):
        self.alpha = alpha
        self.clamp_s = clamp_s
        self._per_device: Dict[str, _OffsetEWMA] = {}

    def _get(self, device: str) -> _OffsetEWMA:
        if device not in self._per_device:
            self._per_device[device] = _OffsetEWMA(self.alpha, self.clamp_s)
        return self._per_device[device]

    def reset(self, device: Optional[str] = None):
        if device is None:
            self._per_device.clear()
        else:
            self._per_device.pop(device, None)

    def map_event_ts(
        self,
        device: str,
        t_device: Optional[float],
        te: Optional[float],
        ts_arrival: Optional[float] = None
    ) -> float:
        ts_arrival = float(ts_arrival) if ts_arrival is not None else local_clock()
        if t_device is not None:
            off = self._get(device).update(ts_arrival - float(t_device))

            # debug: rr更新后的细节
            mapped = float(te) + off if te is not None else float(t_device) + off
            logger.info(f"[ClockSync] map_event_ts t_device={t_device:.6f} te={te} ts_arrival={ts_arrival:.6f} off={off:.6f} mapped={mapped:.6f}")

            if te is not None:
                return float(te) + off
            return float(t_device) + off
        # 没有设备时间，回退到到达时刻
        return ts_arrival