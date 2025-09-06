import time
import serial
import struct
import datetime
import csv, json
import signal
import argparse
import pylsl
from pylsl import StreamInfo, StreamOutlet

import os
import sys
from pathlib import Path

# 让脚本无视工作目录也能 import 到项目根的 paths.py
ROOT = Path(__file__).resolve().parents[3]  # HKH-11C → bridge → src → (root)
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from paths import RECORDER_DATA_DIR

# ----------------------------- 全局停止标志与信号 -----------------------------
STOP_FLAG = False
def _sig_handler(signum, frame):
    global STOP_FLAG
    STOP_FLAG = True
    print(f"[HKH] 收到信号 {signum}，已置位 STOP_FLAG", flush=True)

# ----------------------------- 1) LSL 流定义 ---------------------------------
info = StreamInfo(
    name="HB_Respiration_HKH",
    type="Respiration",
    channel_count=1,
    nominal_srate=50,             # 设备名义采样率 50Hz
    channel_format="int16",
    source_id="HKH_Device",
)
channels = info.desc().append_child("channels")
ch = channels.append_child("channel")
ch.append_child_value("label", "BreathingWave")
ch.append_child_value("unit", "arbitrary_units")
outlet = StreamOutlet(info)

# ----------------------------- 2) 串口与协议 ---------------------------------
BAUD_RATE = 115200
CANDIDATE_PORTS = ["COM5", "COM3"]  # 先尝试 COM5，再尝试 COM3
COM_PORT = None

# 只验证是否能打开，立刻关闭，避免占用句柄
for p in CANDIDATE_PORTS:
    try:
        _probe = serial.Serial(p, BAUD_RATE, timeout=1)
        _probe.close()
        COM_PORT = p
        break
    except Exception:
        continue

if COM_PORT is None:
    print(
        "错误：未能连接 COM3/COM5。\n"
        "请打开“设备管理器→端口（COM & LPT）”，找到呼吸带端口（Silicon Labs CP210x USB to UART Bridge），\n"
        "然后把 CANDIDATE_PORTS 中的端口顺序改到正确端口或直接把 COM_PORT 设为实际端口。",
        flush=True,
    )
    raise SystemExit(3)

DEVICE_ID = 0xCC
CMD_START = b"\xFF\xCC\x03\xA3\xA0"
CMD_STOP  = b"\xFF\xCC\x03\xA4\xA1"

# ----------------------------- 3) 解析参数 -----------------------------------
ap = argparse.ArgumentParser(add_help=False)
ap.add_argument("--session")
ap.add_argument("--under-hub", action="store_true")
ap.add_argument("--hb-interval", type=float, default=2.0)
args, _ = ap.parse_known_args()

SESSION   = args.session or time.strftime("S%Y%m%d-%H%M%S")
UNDER_HUB = args.under_hub
HB_EVERY  = max(0.5, args.hb_interval)

# 注册可软停信号（Win: SIGBREAK；POSIX: SIGINT/SIGTERM）
signal.signal(signal.SIGINT,  _sig_handler)
signal.signal(signal.SIGTERM, _sig_handler)
if hasattr(signal, "SIGBREAK"):
    signal.signal(signal.SIGBREAK, _sig_handler)

# ----------------------------- 4) 输出目录与文件 ------------------------------
ts_str   = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
out_dir  = Path(RECORDER_DATA_DIR) / "HKH" /SESSION
out_dir.mkdir(parents=True, exist_ok=True)
csv_path = out_dir / f"respiration_preview_{ts_str}.csv"
csv_path.parent.mkdir(parents=True, exist_ok=True)

# ----------------------------- 5) 主流程 -------------------------------------
ser = None
try:
    # 交互提示
    print("--- 呼吸信号LSL采集脚本 ---", flush=True)
    print(f"LSL Stream Name: {info.name()}", flush=True)
    print(f"设备端口: {COM_PORT}", flush=True)
    print("[READY] hkh", flush=True)
    if not UNDER_HUB:
        print("提示：在 Lab Recorder 勾选 HB_Respiration_HKH 流；按 ESC/Ctrl-C 可停止。", flush=True)
    print(f"数据将保存至: {csv_path}", flush=True)
    print("-----------------------------------", flush=True)

    # 打开串口与 CSV
    ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=1)
    print(f"成功连接到 {COM_PORT}。", flush=True)

    with open(csv_path, "w", newline="") as csvfile:
        csv_writer = csv.writer(csvfile)
        csv_writer.writerow(["LSL_Timestamp", "BreathingValue"])

        # 发送启动命令
        ser.write(CMD_START)
        if not UNDER_HUB:
            print("按【ESC】键可随时停止录制。", flush=True)
        print("-----------------------------------", flush=True)

        # 心跳定时（独立于是否解析到新帧）
        start_time   = pylsl.local_clock()
        last_hb_time = start_time
        last_value   = 0

        # 读取循环
        while not STOP_FLAG:
            parsed = False

            # 尝试解析一帧：FF | DEVICE_ID | ... 5 字节 payload
            if ser.in_waiting > 0 and ser.read(1) == b"\xFF":
                if ser.in_waiting > 0 and ser.read(1) == bytes([DEVICE_ID]):
                    packet = ser.read(5)
                    if len(packet) == 5:
                        hxh, hxl = packet[3], packet[4]
                        breathing_value = struct.unpack(">h", bytes([hxh, hxl]))[0]

                        # LSL 推送 + CSV 记录
                        t = pylsl.local_clock()
                        outlet.push_sample([breathing_value], t)
                        csv_writer.writerow([t, breathing_value])

                        # 更新“最近值”
                        last_value = int(breathing_value)
                        parsed = True

            # 若没有解析到新包，轻微让出 CPU，避免无谓空转
            if not parsed:
                time.sleep(0.002)

            # 到点就发心跳 JSON（hub 会吃掉并汇总成人话）
            now = pylsl.local_clock()
            if now - last_hb_time >= HB_EVERY:
                elapsed = now - start_time
                hb = {
                    "hb": "hkh",
                    "elapsed_s": elapsed,
                    "recent_samples": int(HB_EVERY * 50),  # 50Hz 估算
                    "last_value": last_value,
                }
                print(json.dumps(hb, ensure_ascii=False), flush=True)
                if not UNDER_HUB:
                    print(f"[HKH] 正在录制：累计 {elapsed:.1f}s，当前呼吸值 {last_value}", flush=True)
                last_hb_time = now

    # 跳出循环（STOP_FLAG 置位）
    print("\n检测到【ESC/信号】，正在停止...", flush=True)

except serial.SerialException as e:
    print(f"\n错误: 无法打开端口 {COM_PORT}。请检查设备连接或端口号。\n{e}", flush=True)
except Exception as e:
    print(f"\n发生未知错误: {e}", flush=True)
finally:
    try:
        if ser and ser.is_open:
            # 向设备发送 STOP 命令，确保硬件灭灯
            try:
                ser.write(CMD_STOP)
                print("已发送停止命令。", flush=True)
            except Exception:
                pass
            ser.close()
            print(f"端口 {COM_PORT} 已关闭。数据已保存至 {csv_path}。", flush=True)
    except Exception:
        pass
