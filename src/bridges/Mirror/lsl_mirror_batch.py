#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
订阅可见 LSL 流，实时写入 Parquet 到 ../UDP2LSL/Data/mirror_lsl_data/<会话>/，不存在会自动创建；
识别 Markers 里的 “stop” 文本或 {"cmd":"stop"}，只记录到 stop_markers.jsonl，不触发停止；
控制台实时打印：发现了哪些流、累计写入多少行、多久没见到数据、是否尚未发现任何流等；
停止条件只有一个：用户在运行 lsl_mirror.py 的终端按下 ESC；其它方式不再内建（Ctrl-C 也会优雅收尾，但不再当作推荐方式）；
压缩与刷新参数设置为“稳重不吃 CPU”。
"""

import time, json, argparse, threading, select
from typing import Dict, Any, List
import signal

from pylsl import resolve_streams, StreamInlet, cf_string
import pyarrow as pa
import pyarrow.parquet as pq

# ----------------- 配置（稳重、低占用） -----------------
# ROOT = Path(__file__).resolve().parent
# OUT_ROOT = ROOT / "Data" / "mirror_lsl_data"

import os
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]  # Polar→bridge→src→(root)
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
# 从我们统一的路径管理器中导入所有需要的数据路径
from paths import MIRROR_DATA_DIR

DISCOVER_EVERY = 5.0        # 每 5s 扫一次现有 LSL 流
PULL_SLEEP     = 0.02       # 主循环休眠（秒）
FLUSH_ROWS     = 10000      # 每 1 万行 flush 一次
FLUSH_SEC      = 3.0        # 或者每 3 秒 flush 一次
COMPRESSION    = "snappy"   # 轻量压缩；要极致稳可改为 None

# ----------------- 工具函数 -----------------
def now_session_id() -> str:
    return time.strftime("S%Y%m%d-%H%M%S")

def is_numeric_format(fmt) -> bool:
    """LSL channel_format 可能是整数枚举或字符串；把 string 判为非数值，其余按数值。"""
    if isinstance(fmt, int):
        return fmt != cf_string
    s = (str(fmt) if fmt is not None else "").lower()
    return s not in ("string", "str", "cf_string")

def inlet_meta_dict(info) -> Dict[str, Any]:
    desc = info.desc()
    meta = {
        "name": info.name(),
        "type": (info.type() or "").upper(),
        "source_id": info.source_id(),
        "channel_count": info.channel_count(),
        "nominal_srate": info.nominal_srate(),
        "channel_format": info.channel_format(),
    }
    try:
        meta["manufacturer"] = desc.child_value("manufacturer") or ""
        meta["session"] = desc.child_value("session") or ""
    except Exception:
        pass
    return meta

def build_numeric_schema(ch: int) -> pa.schema:
    fields = [pa.field("time_lsl", pa.float64())] + [pa.field(f"ch_{i}", pa.float32()) for i in range(ch)]
    return pa.schema(fields)

def build_string_schema() -> pa.schema:
    return pa.schema([pa.field("time_lsl", pa.float64()), pa.field("value", pa.string())])

# ----------------- 轻量 Parquet 写入器 -----------------
class ParquetWriter:
    def __init__(self, path: Path, schema: pa.schema, flush_rows: int, flush_sec: float, compression=COMPRESSION):
        self.path = path
        self.schema = schema
        self.flush_rows = flush_rows
        self.flush_sec = flush_sec
        self.compression = compression
        self._writer = None
        self._buf: List[pa.RecordBatch] = []
        self._last_flush = time.time()
        self.total_rows = 0

    def _ensure(self):
        if self._writer is None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._writer = pq.ParquetWriter(self.path, self.schema, compression=self.compression)

    def write_batch(self, batch: pa.RecordBatch):
        if batch.num_rows == 0:
            return
        self._buf.append(batch)
        nrows = sum(b.num_rows for b in self._buf)
        if nrows >= self.flush_rows or (time.time() - self._last_flush) >= self.flush_sec:
            self._flush_locked()

    def _flush_locked(self):
        if not self._buf:
            return
        self._ensure()
        table = pa.Table.from_batches(self._buf, schema=self.schema)
        self._writer.write_table(table)
        self.total_rows += table.num_rows
        self._buf.clear()
        self._last_flush = time.time()

    def close(self):
        # 尽量保证尾部 footer 写入（避免半截文件）
        self._flush_locked()
        if self._writer:
            self._writer.close()

# ----------------- 跨平台 ESC 检测 -----------------
class EscWatcher:
    """在主循环里反复调用 .pressed()；按下 ESC 返回 True。"""
    def __init__(self):
        self.is_windows = os.name == "nt"
        if not self.is_windows:
            import termios, tty
            self.termios = termios
            self.tty = tty
            self.fd = sys.stdin.fileno() if sys.stdin.isatty() else None
            self.old = None

    def __enter__(self):
        if not self.is_windows and self.fd is not None:
            self.old = self.termios.tcgetattr(self.fd)
            self.tty.setcbreak(self.fd)
        return self

    def __exit__(self, *exc):
        if not self.is_windows and self.fd is not None and self.old:
            self.termios.tcsetattr(self.fd, self.termios.TCSADRAIN, self.old)

    def pressed(self) -> bool:
        try:
            if self.is_windows:
                import msvcrt
                if msvcrt.kbhit():
                    ch = msvcrt.getch()
                    return ch == b"\x1b"  # ESC
                return False
            else:
                if self.fd is None:
                    return False
                r, _, _ = select.select([sys.stdin], [], [], 0)
                if r:
                    ch = os.read(self.fd, 1)
                    return ch == b"\x1b"
                return False
        except Exception:
            return False

# ----------------- 主类：镜像写手 -----------------
class Mirror:
    def __init__(self, out_root: Path, under_hub: bool = False, hb_every: float = 2.0):
        self.out_root = out_root
        self.under_hub = bool(under_hub)
        self.hb_every = float(hb_every)
        self.session = now_session_id()
        self.session_dir = self.out_root / self.session
        self.session_dir.mkdir(parents=True, exist_ok=True)

        self.index = {"session": self.session, "started_at": time.strftime("%Y-%m-%d %H:%M:%S"), "streams": []}
        (self.session_dir / "session_index.json").write_text(json.dumps(self.index, ensure_ascii=False, indent=2), encoding="utf-8")

        self.inlets: Dict[str, StreamInlet] = {}
        self.meta:   Dict[str, Dict[str, Any]] = {}
        self.writers: Dict[str, ParquetWriter] = {}
        self.schemas: Dict[str, pa.schema] = {}
        self.last_seen: Dict[str, float] = {}
        self.stop_markers = (self.session_dir / "stop_markers.jsonl").open("a", encoding="utf-8")

        self._lock = threading.Lock()
        self._ever_seen_any = False
        self._last_summary = 0.0

    def discover_once(self):
        infos = resolve_streams(wait_time=1.0)
        with self._lock:
            for info in infos:
                sid = info.source_id()
                if not sid or sid in self.inlets:
                    continue
                m = inlet_meta_dict(info)
                inlet = StreamInlet(info, max_buflen=60, processing_flags=0)

                # 文件名：<Name>__<sid8>.parquet
                base = (m["name"] or "LSL").replace("/", "_")
                fname = f"{base}__{sid[:8]}.parquet"

                schema = build_numeric_schema(m["channel_count"]) if is_numeric_format(m["channel_format"]) else build_string_schema()
                writer = ParquetWriter(self.session_dir / fname, schema, FLUSH_ROWS, FLUSH_SEC, COMPRESSION)

                self.inlets[sid] = inlet
                self.meta[sid] = m
                self.schemas[sid] = schema
                self.writers[sid] = writer
                self.last_seen[sid] = 0.0

                self.index["streams"].append({"file": fname, **m})
                (self.session_dir / "session_index.json").write_text(json.dumps(self.index, ensure_ascii=False, indent=2), encoding="utf-8")

                print(f"[mirror] + {m['name']}  stype={m['type']}  ch={m['channel_count']}  fmt={m['channel_format']}  -> {fname}")

    def _write_stop_event(self, when_lsl: float, label: str, stream_name: str):
        rec = {"time_lsl": when_lsl, "label": label, "stream": stream_name}
        try:
            self.stop_markers.write(json.dumps(rec, ensure_ascii=False) + "\n")
            self.stop_markers.flush()
        except Exception:
            pass

    def pull_once(self):
        now = time.time()
        any_data = False
        with self._lock:
            for sid, inlet in list(self.inlets.items()):
                try:
                    samples, ts = inlet.pull_chunk(timeout=0.0)
                except Exception:
                    samples, ts = [], []
                if not samples:
                    continue
                any_data = True
                self._ever_seen_any = True
                self.last_seen[sid] = now

                # 轻量时间校正：限频调用，避免 CPU 抖动
                try:
                    corr = inlet.time_correction(timeout=0.0)
                except Exception:
                    corr = 0.0
                ts_corr = [t + corr for t in ts]

                m = self.meta[sid]
                schema = self.schemas[sid]
                w = self.writers[sid]

                if is_numeric_format(m["channel_format"]):
                    # samples: List[List[float]] 维度 [n, ch]
                    cols = list(zip(*samples)) if samples else []
                    arrays = [pa.array(ts_corr, type=pa.float64())] + [pa.array(c, type=pa.float32()) for c in cols]
                    batch = pa.RecordBatch.from_arrays(arrays, schema=schema)
                else:
                    # 字符/标记流
                    texts = []
                    for s in samples:
                        v = s[0] if isinstance(s, list) and s else s
                        text = str(v)
                        texts.append(text)
                        # 识别 stop，仅记录
                        try:
                            obj = json.loads(text)
                            label = str(obj.get("label", "")).lower()
                            cmd = str(obj.get("cmd", "")).lower()
                            if "stop" in label or cmd == "stop":
                                self._write_stop_event(ts_corr[0], text, m.get("name","?"))
                        except Exception:
                            if "stop" in text.lower():
                                self._write_stop_event(ts_corr[0], text, m.get("name","?"))
                    batch = pa.RecordBatch.from_arrays([pa.array(ts_corr, type=pa.float64()),
                                                        pa.array(texts,   type=pa.string())],
                                                       schema=schema)
                w.write_batch(batch)

        return any_data

    def _summary(self):
        with self._lock:
            n_streams = len(self.writers)
            if n_streams == 0:
                print("[mirror] 未检测到 LSL 数据流；请确保 bridge_hub 与数据源已启动。")
                return
            print(f"[mirror] 活跃流={n_streams}", end="")
            for sid, w in self.writers.items():
                name = (self.meta[sid].get("name") or "?").replace("PB_", "")
                idle = time.time() - (self.last_seen.get(sid, 0) or 0)
                print(f" | {name}: rows={w.total_rows} idle={idle:.1f}s", end="")
            print()

    def run(self):
        # 注册停止信号
        STOP_FLAG = {"v": False}
        def _sig_handler(signum, frame):
            STOP_FLAG["v"] = True
        signal.signal(signal.SIGINT, _sig_handler)
        signal.signal(signal.SIGTERM, _sig_handler)
        if hasattr(signal, "SIGBREAK"):
            signal.signal(signal.SIGBREAK, _sig_handler)   # Windows

        print(f"[mirror] 输出目录: {self.session_dir}", flush=True)
        print("[mirror] 已启动：按 ESC 结束录制。", flush=True)
        print("[READY] mirror", flush=True)
        last_discover = 0.0
        with EscWatcher() as esc:
            try:
                while True:
                    if time.time() - last_discover >= DISCOVER_EVERY:
                        self.discover_once()
                        last_discover = time.time()

                    self.pull_once()
                    time.sleep(PULL_SLEEP)

                    # 打印间隔，根据hub的参数
                    if time.time() - self._last_summary >= self.hb_every:
                        # 先出一条心跳 JSON
                        try:
                            max_idle = 0.0
                            for sid in self.writers.keys():
                                idle = time.time() - (self.last_seen.get(sid,0) or 0)
                                max_idle = max(max_idle, idle)
                            hb = {"hb":"mirror", "streams": len(self.writers),
                                "rows": sum(w.total_rows for w in self.writers.values()),
                                "max_idle_s": round(max_idle,2)}
                            print(json.dumps(hb, ensure_ascii=False), flush=True)
                        except Exception:
                            pass
                        # 仅非 under-hub，再打印人话摘要
                        if not self.under_hub:
                            self._summary()
                        self._last_summary = time.time()


                    if esc.pressed():
                        print("[mirror] 检测到 ESC，准备停止录制镜像数据。", flush=True)
                        break
                        
                    if STOP_FLAG["v"]:
                        print("[mirror] 收到停止信号，准备停止录制镜像数据。", flush=True)
                        break

            except KeyboardInterrupt:
                print("\n[mirror] 用户中断（Ctrl-C）。")
            finally:
                # 关闭写入器，写会话收尾
                for w in list(self.writers.values()):
                    try:
                        w.close()
                    except Exception:
                        pass
                try:
                    self.stop_markers.close()
                except Exception:
                    pass
                end = {"ended_at": time.strftime("%Y-%m-%d %H:%M:%S"),
                       "streams": len(self.index.get("streams", []))}
                try:
                    (self.session_dir / "session_end.json").write_text(
                        json.dumps(end, ensure_ascii=False, indent=2), encoding="utf-8"
                    )
                except Exception:
                    pass
                print(f"[mirror] 录制已停止。session={self.session}", flush=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", help="会话 ID（可选）")
    ap.add_argument("--out", default=str(MIRROR_DATA_DIR), help="输出根目录（默认 UDP2LSL/Data/mirror_lsl_data）")
    ap.add_argument("--under-hub", action="store_true")
    ap.add_argument("--hb-interval", type=float, default=2.0)
    args = ap.parse_args()

    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)
    hb_interval = max(0.5, args.hb_interval)

    m = Mirror(out_root=out_root, under_hub=args.under_hub, hb_every=hb_interval)
    if args.session:
        m.session = args.session
        m.session_dir = out_root / m.session
        m.session_dir.mkdir(parents=True, exist_ok=True)

    m.run()

if __name__ == "__main__":
    main()
