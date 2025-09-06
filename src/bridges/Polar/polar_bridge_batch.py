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

import imp
import sys
import os
from pathlib import Path
# 获取当前工作目录
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from paths import RECORDER_DATA_DIR, PROCESSED_DATA_DIR


# =============================================================================

# ========== 标准库依赖 ==========
import time
import json
import uuid
import socket
import signal
import argparse
import select  # 为 ESC 轮询读取 stdin

# ========== 第三方库依赖 ==========
from pylsl import StreamInfo, StreamOutlet, local_clock

# ========== 本项目内部依赖 (使用绝对路径) ==========
# 从当前文件位置 (__file__) 出发，向上寻找项目根目录
# 我们需要向上走3层 (polar -> bridges -> src) 才能到达 PhysioBridge/ 这个根目录
project_root = Path(__file__).resolve().parent.parent.parent
from src.utils.lsl_registry import LSLRegistry
from src.utils.clock_sync import ClockSync
from src.utils.json_guard import f, rows_as_float
from src.utils.stream_metrics import StreamMetrics 
from src.utils.ping_pong import PingPong

# ========== 同模块内部依赖 (使用相对路径) ==========
# ".parser" 意为 "从当前文件夹(polar/)导入parser.py"
# "as Translators" 保留了别名，我们就不需要修改文件下面调用它的地方
from polar_parser import handle as handle_polar


# ========== 配置 ==========
CONFIG = {
    # UDP 监听地址与端口（iPhone/发包端把目标指向本机IP:PORT）
    "HOST": "0.0.0.0",
    "PORT": 9001,
    # 会话ID 与 LSL 名称后缀
    "SESSION": time.strftime("S%Y%m%d-%H%M%S"),
    "NAME_SUFFIX": "",   # 稳定后可改成 ""
    # 旁路日志目录（逐条 UDP 入站都写一行 .jsonl）
    # "LOGDIR": str((Path(__file__).resolve().parent) / "logs"),
    # 控制台摘要间隔（秒）
    "SUMMARY_EVERY": 3,
    # UDP 接收缓冲（避免高吞吐丢包）
    "SO_RCVBUF": 4 * 1024 * 1024,

}

# 全局停止标志与信号处理
STOP_FLAG = False
def _sig_handler(signum, frame):
    global STOP_FLAG
    STOP_FLAG = True

# 在 main() 开始时注册（

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
    print("按 ESC 结束。")
    print("=" * 72 + "\n")

# ----------------- 跨平台 ESC 监听 -----------------
class EscWatcher:
    """在主循环里反复调用 .pressed()；按下 ESC 返回 True。"""
    def __init__(self):
        self._is_win = os.name == "nt"
        self._fd = None
        self._old = None

    def __enter__(self):
        if not self._is_win and sys.stdin.isatty():
            import termios, tty
            self._termios = termios
            self._tty = tty
            self._fd = sys.stdin.fileno()
            self._old = self._termios.tcgetattr(self._fd)
            self._tty.setcbreak(self._fd)
        return self

    def __exit__(self, *exc):
        if self._fd is not None and self._old is not None:
            try:
                self._termios.tcsetattr(self._fd, self._termios.TCSADRAIN, self._old)
            except Exception:
                pass

    def pressed(self) -> bool:
        try:
            if self._is_win:
                import msvcrt
                if msvcrt.kbhit():
                    ch = msvcrt.getch()
                    return ch == b"\x1b"  # ESC
                return False
            # POSIX：非阻塞读取一个字节
            if not sys.stdin.isatty():
                return False
            r, _, _ = select.select([sys.stdin], [], [], 0)
            if r:
                ch = os.read(sys.stdin.fileno(), 1)
                return ch == b"\x1b"
            return False
        except Exception:
            return False


def main():
    # 注册新号
    # 信号处理与参数
    signal.signal(signal.SIGINT, _sig_handler)
    signal.signal(signal.SIGTERM, _sig_handler)

    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--session")
    ap.add_argument("--under-hub", action="store_true")
    ap.add_argument("--hb-interval", type=float, default=2.0)
    args, _ = ap.parse_known_args()
    if args.session:
        CONFIG["SESSION"] = args.session
    if args.under_hub:
        CONFIG["SUMMARY_EVERY"] = 10**9  # 等效禁用自播报
    else:
        CONFIG["SUMMARY_EVERY"] = max(0.5, args.hb_interval)
    UNDER_HUB = args.under_hub

    # 准备日志 在 recorder_data 下创建本次会话的专属文件夹
    # Path(CONFIG["LOGDIR"]).mkdir(parents=True, exist_ok=True)
    session_id = CONFIG.get("SESSION", time.strftime("S%Y%m%d-%H%M%S"))
    session_dir = PROCESSED_DATA_DIR /  "logs" / session_id
    session_dir.mkdir(parents=True, exist_ok=True)
    print(f"[*] 本次会話數據與日誌將保存至: {session_dir}")

    # 设置日志与 metrics 文件路径，保存在新的会话目录中
    log_path = session_dir / f"{session_id}.log.jsonl"
    logf = open(log_path, "a", buffering=1, encoding="utf-8")
    # 打开一个 metrics.jsonl，用于记录 UDP 丢包/抖动的周期快照
    metrics_path = session_dir / f"{session_id}.metrics.jsonl"
    metricsf = open(metrics_path, "a", buffering=1, encoding="utf-8")

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

    # 丢包计算器
    metrics = StreamMetrics()
    # 每10秒同步一次ping-pong
    pp = PingPong(sock, period_s=10.0)

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
    print("【提示】按 ESC 结束（焦点需在本终端窗口）")

    try:
        with EscWatcher() as esc:
            while True:
                data, addr = sock.recvfrom(65535)
                ts_host = local_clock()

                # 接受来自手机的 pong 包
                recv_monotonic = time.monotonic()

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

                # 接受来自手机的 pong 包: 若是 JSON，做两件事：更新设备->地址；喂给 metrics 与 ping-pong
                if isinstance(obj, dict):
                    # 1) 记录设备地址（用于单播 ping），device 字段名按你 Swift 的包体来
                    typ = obj.get("type")
                    dev = obj.get("device") or obj.get("deviceLabel") or obj.get("deviceId")
                    if dev:
                        pp.update_endpoint(dev, addr)

                    control_types = {"ping", "pong", "hub_status"}
                    if typ in control_types:
                        # 控制包：只做 timesync，不进入丢包统计与翻译器
                        if typ == "pong":
                            pp.on_datagram_json(obj, recv_t_pc=time.time(), device_hint=dev)
                        routed_marker = True  # NEW: 避免下面被算作 unknown
                    else:
                        # 业务包：进入丢包统计；如有需要，下面继续交给翻译器
                        metrics.observe(obj, recv_monotonic)
                        # 非 pong 的业务包不需要 timesync 处理

                # 翻译器：仅当 obj 是 dict 时尝试解析与产出数值型 LSL
                if isinstance(obj, dict) and not routed_marker:
                    # 翻译器：仅当 obj 是 dict 时尝试解析与产出数值型 LSL
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

                    hb = {"hb":"polar", "udp_pkts": cnt_text, "handled": cnt_handled,
                    "unknown": cnt_unknown, "errors": cnt_errors,
                    "udp_loss": metrics.total_loss(),  # 如果没有这个方法，可用 metrics.snapshot() 里算百分比
                    "lat_avg_ms": round(clock.avg_latency_ms(), 1) if hasattr(clock,"avg_latency_ms") else 0}
                    print(json.dumps(hb, ensure_ascii=False))

                    print("  手机-电脑时间同步 :", json.dumps(pp.snapshot(), ensure_ascii=False))

                    if cnt_handled == 0:
                        print("  提示：若数值流未出现，请确认手机端已开始发送；Lab Recorder 可先打开等待。")

                    # 打印 UDP 丢包统计的简报
                    print("  UDP:", metrics.format_brief())

                    # 对已知设备单播发一轮 ping（间隔受 period_s 限制）
                    pp.maybe_send_pings()

                    # 将当前快照写入 metrics.jsonl，便于事后出报告
                    try:
                        snap = {
                            "ts": time.time(),
                            "snapshot": metrics.snapshot(),  # 每个 key 是 "device|type"
                            "timesync": pp.snapshot(),  # 时钟同步状态
                        }
                        metricsf.write(json.dumps(snap, ensure_ascii=False) + "\n")
                    except Exception:
                        pass
                    
                    t0 = now
                    
                # + 在每轮循环末尾顺手检测一次 ESC
                if esc.pressed():
                    print("[bridge_hub] 您按下了 ESC 键，准备停止录制...")
                    break
                
                # 接收到到停止信号 也停止
                if STOP_FLAG:
                    print("[bridge_hub] 收到停止信号，准备停止录制...")
                    break


    except KeyboardInterrupt:
        print("\n[bridge_hub] 用户打断录制，停止录制...")
        
    finally:
        try:
            sock.close()
        except Exception:
            pass
        try:
            logf.close()
        except Exception:
            pass
        # 关闭 metrics 文件
        try:
            metricsf.close()
        except Exception:
            pass
        except Exception:
            pass
        print("[bridge_hub] closed UDP socket and log file.")


if __name__ == "__main__":
    main()
