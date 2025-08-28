#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bridge_hub.py  —  单脚本一键桥接 + 翻译 + 指南输出

功能：
1) 绑定 UDP，接收 iOS 端发来的 JSON 文本；
2) 创建两路基础 LSL：
   - PB_UDP      (stype=udp_text)  原始文本旁路
   - PB_MARKERS  (stype=Markers)   只存 marker 标签
3) 同时把可识别的 JSON 交给 Translators（现含 polar_numberic），
   直接产出数值型 LSL：RR/PPI/HR/ECG/ACC/PPG
4) 控制台持续输出“当前状态”和“下一步建议动作”。

只需运行本脚本，不再需要单独运行 udp_to_lsl.py。
"""

import os
import sys
import time
import json
import uuid
import socket
from pathlib import Path
from typing import Any, Dict, List

# ========== 路径注入：保证能 import 到 Libs/ 与 Translators/ ==========
ROOT = os.path.abspath(os.path.dirname(__file__))
LIBS = os.path.join(ROOT, "Libs")
TRANS = os.path.join(ROOT, "Translators")
for p in (ROOT, LIBS, TRANS):
    if p not in sys.path:
        sys.path.append(p)

# ========== 依赖 ==========
from pylsl import StreamInfo, StreamOutlet, local_clock

# 工具与注册表
from Libs.clock_sync import ClockSync
from Libs.lsl_registry import LSLRegistry
from Libs.json_guard import f as fnum, rows_as_float

# 翻译器（Polar）
# 注意：你的文件名是 polar_numberic.py（拼写如此），保持一致
from Translators.polar_numberic import handle as handle_polar


# ========== 配置 ==========
CONFIG = {
    # UDP 监听地址与端口（iPhone/发包端把目标指向本机IP:PORT）
    "HOST": "0.0.0.0",
    "PORT": 9001,

    # 会话ID 与 LSL 名称后缀
    "SESSION": time.strftime("S%Y%m%d-%H%M%S"),
    "NAME_SUFFIX": "",   # 稳定后可改成 ""

    # 旁路日志目录（逐条 UDP 入站都写一行 .jsonl）
    "LOGDIR": str(Path.home() / "lsl_logs"),

    # 控制台摘要间隔（秒）
    "SUMMARY_EVERY": 5,

    # UDP 接收缓冲（避免高吞吐丢包）
    "SO_RCVBUF": 4 * 1024 * 1024,
}


# ========== 内部工具 ==========
def _name(base: str) -> str:
    suf = CONFIG["NAME_SUFFIX"] or ""
    return f"{base}{suf}"


def _make_outlet(name: str, stype: str, source_id: str, channel_format: str = "string"):
    info = StreamInfo(name, stype, 1, 0.0, channel_format, source_id)
    desc = info.desc()
    desc.append_child_value("impl", "bridge_hub_integrated")
    desc.append_child_value("session", CONFIG["SESSION"])
    desc.append_child_value("created_at", time.strftime("%Y-%m-%dT%H:%M:%S"))
    return info, StreamOutlet(info, chunk_size=0, max_buffered=360)


def _status_banner(host_ip: str, name_udp: str, name_mark: str, log_path: Path):
    print("\n" + "=" * 72)
    print("[BridgeHub] 已启动并完成基础通道搭建")
    print("- UDP 监听:           {}:{}".format(host_ip, CONFIG["PORT"]))
    print("- LSL 文本流:         {} (stype=udp_text)".format(name_udp))
    print("- LSL 标记流:         {} (stype=Markers)".format(name_mark))
    print("- 旁路日志:           {}".format(str(log_path)))
    print("- 已加载翻译器:       polar_numberic (RR/PPI/HR/ECG/ACC/PPG)")
    print("\n下一步建议：")
    print("1) 打开 Lab Recorder，刷新或进入选择界面；你会看到：")
    print("   - 数值流：PB_RR_*/PB_PPI_*/PB_HR_*/PB_ECG_*/PB_ACC_*/PB_PPG_*")
    print("   - 文本流：{}；标记流：{}".format(name_udp, name_mark))
    print("2) 在手机上打开 PolarBridge，连接设备并开始采集。")
    print("3) 本窗口将打印 [LSL] create ... 表示数值型 LSL 流已经创建；")
    print("   handled 计数会上升表示翻译器正在工作。")
    print("按 Ctrl-C 结束。")
    print("=" * 72 + "\n")


def main():
    # 准备日志
    Path(CONFIG["LOGDIR"]).mkdir(parents=True, exist_ok=True)
    log_path = Path(CONFIG["LOGDIR"]) / f"{CONFIG['SESSION']}.jsonl"
    logf = open(log_path, "a", buffering=1, encoding="utf-8")

    # 绑定 UDP
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 调大接收缓冲
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, CONFIG["SO_RCVBUF"])
        sock.bind((CONFIG["HOST"], CONFIG["PORT"]))
    except OSError as e:
        print(f"[FATAL] UDP {CONFIG['HOST']}:{CONFIG['PORT']} bind failed: {e}")
        return
    sock.setblocking(True)

    # 唯一 source_id
    sid_data = f"pb_udp_{CONFIG['SESSION']}_{uuid.uuid4().hex[:8]}"
    sid_mark = f"pb_markers_{CONFIG['SESSION']}_{uuid.uuid4().hex[:8]}"

    # 两路 LSL 基础流（文本 + 标记）
    name_data = _name("PB_UDP")
    name_mark = _name("PB_MARKERS")
    info_data, outlet_data = _make_outlet(name_data, "udp_text", sid_data)
    info_mark, outlet_mark = _make_outlet(name_mark, "Markers", sid_mark)

    # 翻译器与时间映射
    registry = LSLRegistry(session_label=CONFIG["NAME_SUFFIX"])
    clock = ClockSync(alpha=0.05, clamp_s=1.0)
    translators = [handle_polar]

    # 统计
    cnt_text = 0       # 推到 PB_UDP 的条数
    cnt_mark = 0       # 推到 PB_MARKERS 的条数
    cnt_handled = 0    # 被 translators 处理的条数
    cnt_unknown = 0    # JSON 但未被任何 translator 接住
    cnt_errors = 0     # 翻译器报错次数
    t0 = time.time()

    # 启动即点亮两路流
    # 1) 文本旁路：推一条 hub 状态
    outlet_data.push_sample(
        [json.dumps({"type": "hub_status", "event": "started", "t_host": time.time()})],
        timestamp=local_clock()
    )
    cnt_text += 1
    # 2) 标记流：推一个初始化标记
    outlet_mark.push_sample(["[init]"], timestamp=local_clock())
    cnt_mark += 1

    # 控制台状态
    host_ip = "0.0.0.0"
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))
        host_ip = probe.getsockname()[0]
        probe.close()
    except Exception:
        pass

    print(f"[bridge_hub] session={CONFIG['SESSION']}")
    print(f"[bridge_hub] listening UDP on {CONFIG['HOST']}:{CONFIG['PORT']}")
    print(f"[bridge_hub] LSL outlets ready: {name_data} (udp_text), {name_mark} (Markers)")
    print(f"[bridge_hub] log file: {log_path}")
    _status_banner(host_ip, name_data, name_mark, log_path)

    try:
        while True:
            data, addr = sock.recvfrom(65535)
            ts_host = local_clock()

            # 尝试以 UTF-8 解码；失败则按字节统计
            try:
                text = data.decode("utf-8", errors="ignore").strip()
            except Exception:
                text = f"<{len(data)} bytes>"

            # 旁路日志：每条 UDP 入站都写盘
            try:
                logf.write(json.dumps({"ts_host": time.time(), "remote": addr, "raw": text}) + "\n")
            except Exception:
                pass

            # 路由 1：Marker 单独走标记流
            routed_marker = False
            try:
                obj = json.loads(text)
                if isinstance(obj, dict) and obj.get("type") == "marker":
                    raw_label = obj.get("label", "")
                    label = raw_label if isinstance(raw_label, str) and raw_label.strip() else "unknown"
                    outlet_mark.push_sample([label], timestamp=ts_host)
                    cnt_mark += 1
                    print(f"[MARK #{cnt_mark}] {addr} -> {label}")
                    routed_marker = True
            except Exception:
                obj = None  # 不是 JSON，就让 obj 为 None

            # 路由 2：原样文本始终推到 PB_UDP
            outlet_data.push_sample([text], timestamp=ts_host)
            cnt_text += 1

            # 翻译器：仅当 obj 是 dict 时尝试解析与产出数值型 LSL
            if isinstance(obj, dict) and not routed_marker:
                handled = False
                for handler in translators:
                    try:
                        if handler(obj, ts_host, registry, clock):
                            handled = True
                            cnt_handled += 1
                            break
                    except Exception as e:
                        cnt_errors += 1
                        # 控制台保留简短错误，避免刷屏；需要的话这里可以加 trace
                        print(f"[hub][handler-error] {handler.__name__}: {e}")
                if not handled:
                    cnt_unknown += 1

            # 周期性摘要与温馨提示
            now = time.time()
            if now - t0 >= CONFIG["SUMMARY_EVERY"]:
                print(f"[SUMMARY] text={cnt_text} markers={cnt_mark} handled={cnt_handled} unknown={cnt_unknown} errors={cnt_errors}")
                if cnt_handled == 0:
                    print("  提示：若数值流未出现，请确认手机端已开始发送；Lab Recorder 可先打开等待。")
                t0 = now

    except KeyboardInterrupt:
        print("\n[bridge_hub] interrupted by user. shutting down...")
    finally:
        try:
            sock.close()
        except Exception:
            pass
        try:
            logf.close()
        except Exception:
            pass
        print("[bridge_hub] closed UDP socket and log file.")


if __name__ == "__main__":
    main()
