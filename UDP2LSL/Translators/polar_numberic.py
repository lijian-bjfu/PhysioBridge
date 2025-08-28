# -*- coding: utf-8 -*-
# 翻译 Polar 的 JSON 包为数值型 LSL 流。事件流用 ClockSync 做时间映射，定频流先按 v1 不推 per-sample 时间戳。

"""
Translators/polar_numberic.py
解析 PolarBridge iOS 侧的 JSON 包（RR/PPI/HR/ECG/ACC/PPG），
做时间轴映射并以数值型 LSL 输出。
数据里的属性要对照/PolarBridge/Models/TelemetryModel.swift 中的定义。
"""

from typing import Any, Dict, List
from Libs.lsl_registry import LSLRegistry
from Libs.clock_sync import ClockSync
from Libs.json_guard import f, rows_as_float


def handle(obj: Dict[str, Any], host_ts: float, registry: LSLRegistry, clock: ClockSync) -> bool:
    typ = obj.get("type")
    if not isinstance(typ, str):
        return False
    if typ not in ("rr", "ppi", "hr", "ecg", "acc", "ppg"):
        return False

    device = str(obj.get("device") or "Unknown")
    t_dev = f(obj.get("t_device"))
    te = f(obj.get("te"))

    # 事件流：PPI（6通道：ms, quality, blocker, skinContact, skinSupported）
    typ = str(obj.get("type", "")).strip().lower()  # ← 放在 handle() 顶部或分支前，统一小写
    if typ == "ppi":
        # 数值提取：保证所有变量都有定义
        ms = f(obj.get("ms"))
        if ms is None:
            return False  # 没有 ms 就不处理

        q_raw = f(obj.get("quality"))         # 可能为 None
        qv = q_raw if q_raw is not None else float("nan")

        # 这三个标志 iOS 端按 0/1 发来；统一转 float 便于 LSL/CSV
        blocker        = 1.0 if obj.get("blocker") in (1, True) else 0.0
        skin_contact   = 1.0 if obj.get("skinContact") in (1, True) else 0.0
        skin_supported = 1.0 if obj.get("skinSupported") in (1, True) else 0.0

        device  = str(obj.get("device", "Polar"))
        t_dev   = obj.get("t_device")
        te      = obj.get("te")
        ts_lsl  = clock.map_event_ts(device, t_dev, te, host_ts)

        out = registry.ensure(
            "ppi", device,
            channels=6, srate=0.0,
            units="ms,quality,blocker,skinContact,skinSupported,te"
        )
        out.push_sample(
            [ms, qv, blocker, skin_contact, skin_supported, 
            (float(te) if te is not None else float("nan"))], 
            timestamp=ts_lsl)
        return True



    # 事件流：HR（bpm 单值）
    if typ == "hr":
        bpm = f(obj.get("bpm"))
        if bpm is None:
            return False
        ts = clock.map_event_ts(device, t_dev, None, host_ts)
        out = registry.ensure("hr", device, channels=1, srate=0.0, units="bpm")
        out.push_sample([bpm], timestamp=ts)
        return True

    # 定频：ECG（uV 单通道）
    if typ == "ecg":
        fs = f(obj.get("fs"))
        uV = obj.get("uV")
        if fs is None or not isinstance(uV, list) or not uV:
            return False
        rows = [[float(x)] for x in uV if isinstance(x, (int, float))]
        if not rows:
            return False
        out = registry.ensure("ecg", device, channels=1, srate=fs, units="uV")
        out.push_chunk(rows)  # v1：不附带逐样本时间戳
        return True

    # 定频：ACC（mG 三通道）
    if typ == "acc":
        fs = f(obj.get("fs"))
        mG = obj.get("mG")
        if fs is None or not isinstance(mG, list) or not mG:
            return False
        rows = rows_as_float(mG, 3)
        if not rows:
            return False
        out = registry.ensure("acc", device, channels=3, srate=fs, units="mG")
        out.push_chunk(rows)
        return True

    # 定频：PPG（mU 多通道）
    if typ == "ppg":
        fs = f(obj.get("fs"))
        ch_val = obj.get("ch")
        try:
            ch = int(ch_val)
        except Exception:
            ch = 0
        mU = obj.get("mU")
        if fs is None or ch <= 0 or not isinstance(mU, list) or not mU:
            return False
        rows = rows_as_float(mU, ch)
        if not rows:
            return False
        out = registry.ensure("ppg", device, channels=ch, srate=fs, units="a.u.")
        out.push_chunk(rows)
        return True

    # 事件流：RR（心搏间期，单位 ms；单通道）
    if typ == "rr":
        ms = f(obj.get("ms"))
        if ms is None:
            return False
        ts = clock.map_event_ts(device, t_dev, te, host_ts)
        out = registry.ensure("rr", device, channels=2, srate=0.0, units="ms,te")
        out.push_sample([ms, (float(te) if te is not None else float("nan"))], timestamp=ts)
        return True

    return False