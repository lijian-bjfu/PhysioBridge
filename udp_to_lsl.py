#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# ── 配置区：只改这里 ────────────────────────────────────────────────
from pathlib import Path
import time

CONFIG = {
    # UDP 监听地址与端口（iPhone/发包端要把目标指向本机IP:PORT）
    "HOST": "0.0.0.0",
    "PORT": 9001,

    # 会话ID：默认用时间戳。若想手工固定，改成 "S20250820-01" 这类字符串
    "SESSION": time.strftime("S%Y%m%d-%H%M%S"),

    # LSL 流名后缀：开发期建议用 "_TEST"，稳定后可改成空字符串 ""
    "NAME_SUFFIX": "_TEST",

    # 旁路日志目录（逐条 UDP 入站会落到这里的 .jsonl）
    "LOGDIR": str(Path.home() / "lsl_logs"),

    # 控制台统计摘要的间隔秒数
    "SUMMARY_EVERY": 5,
}
# ────────────────────────────────────────────────────────────────

import socket, json, uuid, os
from pylsl import StreamInfo, StreamOutlet, local_clock

def _name(base: str) -> str:
    suf = CONFIG["NAME_SUFFIX"] or ""
    return f"{base}{suf}"

def _make_outlet(name: str, stype: str, source_id: str, channel_format: str = "string"):
    info = StreamInfo(name, stype, 1, 0.0, channel_format, source_id)
    desc = info.desc()
    desc.append_child_value("impl", "udp_to_lsl_v2")
    desc.append_child_value("session", CONFIG["SESSION"])
    desc.append_child_value("created_at", time.strftime("%Y-%m-%dT%H:%M:%S"))
    return info, StreamOutlet(info, chunk_size=0, max_buffered=360)

def main():
    # 准备日志
    Path(CONFIG["LOGDIR"]).mkdir(parents=True, exist_ok=True)
    log_path = Path(CONFIG["LOGDIR"]) / f"{CONFIG['SESSION']}.jsonl"
    logf = open(log_path, "a", buffering=1, encoding="utf-8")

    # 绑定 UDP
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((CONFIG["HOST"], CONFIG["PORT"]))
    except OSError as e:
        print(f"[FATAL] UDP {CONFIG['HOST']}:{CONFIG['PORT']} bind failed: {e}")
        return
    sock.setblocking(True)

    # 唯一 source_id
    sid_data = f"pb_udp_{CONFIG['SESSION']}_{uuid.uuid4().hex[:8]}"
    sid_mark = f"pb_markers_{CONFIG['SESSION']}_{uuid.uuid4().hex[:8]}"

    # 两路 LSL 流
    name_data = _name("PB_UDP")
    name_mark = _name("PB_MARKERS")
    info_data, outlet_data = _make_outlet(name_data, "udp_text", sid_data)
    info_mark, outlet_mark = _make_outlet(name_mark, "Markers",  sid_mark)

    print(f"[udp_to_lsl] session={CONFIG['SESSION']}")
    print(f"[udp_to_lsl] listening on {CONFIG['HOST']}:{CONFIG['PORT']}")
    print(f"[udp_to_lsl] LSL outlets: {name_data} (sid={sid_data}), {name_mark} (sid={sid_mark})")
    print(f"[udp_to_lsl] log file: {log_path}")

    count_data = 0
    count_mark = 0
    t0 = time.time()

    while True:
        data, addr = sock.recvfrom(65535)
        ts = local_clock()

        try:
            text = data.decode("utf-8", errors="ignore").strip()
        except Exception:
            text = f"<{len(data)} bytes>"

        # 旁路日志：每条 UDP 入站都写盘
        logf.write(json.dumps({"ts_host": time.time(), "remote": addr, "raw": text}) + "\n")

        # 路由：marker 单独走标记流，其它都进数据流
        routed = False
        try:
            obj = json.loads(text)
            if isinstance(obj, dict) and obj.get("type") == "marker":
                raw_label = obj.get("label", "")
                label = raw_label if isinstance(raw_label, str) and raw_label.strip() else "unknown"
                outlet_mark.push_sample([label], timestamp=ts)
                count_mark += 1
                print(f"[MARK #{count_mark}] {addr} -> {label}")
                routed = True
        except Exception:
            pass

        if not routed:
            outlet_data.push_sample([text], timestamp=ts)
            count_data += 1
            print(f"[DATA #{count_data}] {addr} -> {text}")

        # 周期性摘要
        now = time.time()
        if now - t0 >= CONFIG["SUMMARY_EVERY"]:
            print(f"[SUMMARY] data={count_data}, markers={count_mark}, elapsed={int(now - t0)}s")
            t0 = now

if __name__ == "__main__":
    main()
