# -*- coding: utf-8 -*-
"""
Ping-pong time sync for UDP: send {"type":"ping","t0_pc":...} to phone,
expect {"type":"pong","t0_pc":...,"t1_ph":...,"t2_ph":...} back.
Computes RTT and clock offset (NTP-like) per device.
"""

import json, socket, time
from typing import Dict, Tuple, Optional

class PingPong:
    def __init__(self, sock: socket.socket, period_s: float = 10.0):
        self.sock = sock
        self.period = period_s
        # 设备到 (ip, port)
        self.endpoints: Dict[str, Tuple[str, int]] = {}
        # 最近一次测量
        self.last: Dict[str, dict] = {}
        # 待回包缓存（device -> t0_pc）
        self._pending: Dict[str, float] = {}
        self._last_sent_ts = 0.0

    def update_endpoint(self, device: Optional[str], addr: Tuple[str, int]):
        """在 bridge_hub 收到任何该 device 的包时调用，记录其 (ip,port)"""
        if not device:
            return
        self.endpoints[device] = addr

    def maybe_send_pings(self):
        """每次 SUMMARY 时调用；按 period_s 给所有已知设备发一个 ping"""
        now = time.time()
        if now - self._last_sent_ts < self.period:
            return
        self._last_sent_ts = now
        for dev, (ip, port) in list(self.endpoints.items()):
            t0 = time.time()
            pkt = {"type": "ping", "t0_pc": t0, "device": dev}
            try:
                self.sock.sendto(json.dumps(pkt).encode("utf-8"), (ip, port))
                self._pending[dev] = t0
            except Exception:
                pass

    def on_datagram_json(self, obj: dict, recv_t_pc: float, device_hint: Optional[str]=None):
        """在 bridge_hub 收到 JSON 后调用；用于处理 pong"""
        if obj.get("type") != "pong":
            return
        dev = device_hint or obj.get("device") or obj.get("deviceLabel") or "UNKNOWN"
        t0 = obj.get("t0_pc")
        t1 = obj.get("t1_ph")
        t2 = obj.get("t2_ph")
        t3 = recv_t_pc
        try:
            t0 = float(t0); t1 = float(t1); t2 = float(t2)
        except Exception:
            return
        # 只有和我们最近发出的相同 dev 的 ping 对上，才计算
        pend = self._pending.get(dev)
        if not pend or abs(pend - t0) > 2.0:
            # 来自旧 ping 或跨设备的回包，忽略
            return
        rtt = (t3 - t0) - (t2 - t1)
        offset = ((t1 - t0) + (t2 - t3)) / 2.0
        self.last[dev] = {
            "ts_pc": t3,
            "rtt_ms": max(0.0, rtt*1000.0),
            "offset_ms": offset*1000.0
        }
        # 清掉 pending，避免重复匹配
        self._pending.pop(dev, None)

    def snapshot(self):
        """给 bridge_hub 写入 metrics.jsonl 用"""
        return self.last.copy()
