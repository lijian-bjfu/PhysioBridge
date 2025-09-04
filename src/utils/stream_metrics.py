# UDP2LSL/Libs/udp_metrics.py
# -*- coding: utf-8 -*-
"""
UDP metrics: per-stream packet loss, reordering, and inter-arrival jitter.
Keyed by (device, type). Requires iOS JSON to include 'seq'.
For fixed-rate streams (ecg/ppg/acc) also estimates sample throughput vs. fs.
"""

from collections import deque, defaultdict
import time
from typing import Dict, Tuple, Optional

Key = Tuple[str, str]  # (device, type)

EVENT_TYPES = {"rr", "hr", "ppi"}
CONTROL_TYPES = {"ping", "pong", "hub_status"}

class _Win:
    """rolling window for arrival timestamps and sample-throughput"""
    def __init__(self, seconds: float):
        self.seconds = seconds
        self.arrivals = deque()          # monotonic times of packet arrival
        self.samples = deque()           # (monotonic_time, n_samples, fs) if present

    def add_arrival(self, t_mono: float):
        self.arrivals.append(t_mono)
        self._prune(t_mono)

    def add_samples(self, t_mono: float, n: int, fs: Optional[float]):
        self.samples.append((t_mono, int(n), float(fs) if fs else 0.0))
        self._prune(t_mono)

    def _prune(self, now: float):
        cutoff = now - self.seconds
        while self.arrivals and self.arrivals[0] < cutoff:
            self.arrivals.popleft()
        while self.samples and self.samples[0][0] < cutoff:
            self.samples.popleft()

    def interarrival_stats(self) -> Dict[str, float]:
        dq = self.arrivals
        if len(dq) < 2:
            return {"rate_hz": 0.0, "jitter_ms": 0.0}
        dts = [b - a for a, b in zip(dq, list(dq)[1:])]
        mean = sum(dts) / len(dts)
        var = sum((x - mean) ** 2 for x in dts) / max(1, len(dts) - 1)
        return {
            "rate_hz": (1.0 / mean) if mean > 0 else 0.0,
            "jitter_ms": (var ** 0.5) * 1000.0
        }

    def sample_stats(self) -> Dict[str, float]:
        """for fixed-rate streams only; returns arrived vs. theoretical"""
        if not self.samples:
            return {"arrived": 0.0, "expected": 0.0, "gap": 0.0}
        now = self.samples[-1][0]
        start = self.samples[0][0]
        elapsed = max(0.0, min(self.seconds, now - start))
        arrived = float(sum(n for _, n, _ in self.samples))
        # 最后一次 fs 视为当前 fs（实践里足够用）
        fs = 0.0
        for _, _, f in reversed(self.samples):
            if f > 0:
                fs = f; break
        expected = fs * elapsed if fs > 0 else 0.0
        gap = max(0.0, expected - arrived)
        return {"arrived": arrived, "expected": expected, "gap": gap}


class StreamMetrics:
    def __init__(self, win_short: float = 10.0, win_long: float = 60.0):
        self.win_short = win_short
        self.win_long = win_long
        self.last_seq: Dict[Key, int] = {}
        self.pkts_recv: Dict[Key, int] = defaultdict(int)
        self.pkts_miss: Dict[Key, int] = defaultdict(int)
        self.pkts_ooo:  Dict[Key, int] = defaultdict(int)   # out-of-order
        self.wins_s: Dict[Key, _Win] = defaultdict(lambda: _Win(win_short))
        self.wins_l: Dict[Key, _Win] = defaultdict(lambda: _Win(win_long))

    @staticmethod
    def _key(j: dict) -> Optional[Key]:
        typ = j.get("type")
        dev = j.get("device") or j.get("deviceLabel") or j.get("deviceId")
        if not isinstance(typ, str) or not isinstance(dev, str):
            return None
        return (dev, typ)

    def observe(self, j: dict, t_mono: float):
        # 先把控制包过滤掉，避免污染统计
        typ = j.get("type")
        if isinstance(typ, str) and typ in CONTROL_TYPES:
            return

        k = self._key(j)
        if k is None:
            return

        # packet-level
        self.pkts_recv[k] += 1
        seq = j.get("seq")
        if isinstance(seq, int):
            last = self.last_seq.get(k)
            if last is not None:
                gap = seq - last - 1
                if gap > 0:
                    self.pkts_miss[k] += gap
                elif gap < 0:
                    self.pkts_ooo[k] += 1
            self.last_seq[k] = seq

        # arrival windows
        self.wins_s[k].add_arrival(t_mono)
        self.wins_l[k].add_arrival(t_mono)

        # sample-throughput for fixed-rate streams
        fs = j.get("fs")
        n  = j.get("n")
        if isinstance(fs, (int, float)) and isinstance(n, int):
            self.wins_s[k].add_samples(t_mono, n, float(fs))
            self.wins_l[k].add_samples(t_mono, n, float(fs))

    def snapshot(self) -> Dict[str, dict]:
        out = {}
        for k in set(list(self.pkts_recv.keys()) + list(self.wins_l.keys())):
            recv = self.pkts_recv[k]
            miss = self.pkts_miss[k]
            ooo  = self.pkts_ooo[k]
            s_ai = self.wins_s[k].interarrival_stats()
            l_ai = self.wins_l[k].interarrival_stats()
            l_sm = self.wins_l[k].sample_stats()
            out[f"{k[0]}|{k[1]}"] = {
                "pkts": {"recv": recv, "miss": miss, "ooo": ooo,
                         "loss_rate": (miss / (recv + miss)) if (recv + miss) > 0 else 0.0},
                "ia_10s": s_ai,
                "ia_60s": l_ai,
                "samples_60s": l_sm,   # 只有定频流才有意义
            }
        return out

    def format_brief(self) -> str:
        snap = self.snapshot()
        lines = []
        for key in sorted(snap.keys()):
            s = snap[key]
            recv = s["pkts"]["recv"]
            miss = s["pkts"]["miss"]
            lr   = s["pkts"]["loss_rate"] * 100.0
            rate = s["ia_10s"]["rate_hz"]

            # 解析出类型，决定是否显示 jitter / gap
            try:
                dev, typ = key.split("|", 1)
            except ValueError:
                typ = ""

            if typ in EVENT_TYPES:
                jitter_str = "—"                    # 事件流不看 jitter（是生理节奏）
                gap_str = ""                        # 事件流没有 gap60s 的意义
                line = (f"{key}: pkts={recv} miss={miss} ({lr:.2f}%)  "
                        f"rate={rate:.1f}Hz  jitter={jitter_str}")
            else:
                jitter = s["ia_10s"]["jitter_ms"]
                gap    = s["samples_60s"]["gap"]
                gap_str = f"  gap60s={gap:.0f}" if gap > 0 else "  gap60s=0"
                line = (f"{key}: pkts={recv} miss={miss} ({lr:.2f}%)  "
                        f"rate={rate:.1f}Hz  jitter={jitter:.1f}ms{gap_str}")

            lines.append(line)

        return ("  \n".join(lines)) if lines else "(no streams)"

