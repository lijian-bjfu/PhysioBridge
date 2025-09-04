# -*- coding: utf-8 -*-
# 统一管理数值型 LSL 输出 outlet 的创建与复用，避免重复创建。

"""
Libs/lsl_registry.py
统一管理数值型 LSL outlet 的创建与复用。
命名：PB_<TYPE>_<DEVICE>，stype=<TYPE>；desc() 写入简要元信息。
"""

from typing import Dict, Optional
from pylsl import StreamInfo, StreamOutlet


class LSLRegistry:
    def __init__(self, session_label: Optional[str] = None):
        self._outlets: Dict[str, StreamOutlet] = {}
        self._infos: Dict[str, StreamInfo] = {}
        self._session = session_label or ""

    def _key(self, typ: str, device: str) -> str:
        return f"{typ.upper()}::{device}"

    def ensure(
        self,
        typ: str,
        device: str,
        channels: int,
        srate: float,
        units: str = "",
        **meta
    ) -> StreamOutlet:
        key = self._key(typ, device)
        if key in self._outlets:
            return self._outlets[key]

        name = f"PB_{typ.upper()}_{device}{self._session}"
        stype = typ.upper()
        source_id = f"pb_{typ}_{device}_{self._session}".strip("_")

        info = StreamInfo(name, stype, channels, srate, "float32", source_id)
        desc = info.desc()
        desc.append_child_value("impl", "bridge_hub")
        if self._session:
            desc.append_child_value("session", self._session)
        if units:
            desc.append_child_value("units", units)
        for k, v in meta.items():
            desc.append_child_value(str(k), str(v))

        outlet = StreamOutlet(info, chunk_size=0, max_buffered=360)
        self._outlets[key] = outlet
        self._infos[key] = info
        print(f"[LSL] create {name} stype={stype} ch={channels} fs={srate} units={units} meta={meta}")
        return outlet
