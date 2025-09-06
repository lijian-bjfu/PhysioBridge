import imp
import time
import os
from paht import Path
import serial
import struct
import datetime
import csv
import signal
import argparse
import pylsl
from pylsl import StreamInfo, StreamOutlet

import sys
# 获取当前工作目录
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)
# 从我们统一的路径管理器中导入所有需要的数据路径
from paths import RECORDER_DATA_DIR

# 全局停止标志与信号处理
STOP_FLAG = False
def _sig_handler(signum, frame):
    global STOP_FLAG
    STOP_FLAG = True

# =============================================================================
# 1. LSL和文件参数设置
# =============================================================================
# LSL流信息
info = StreamInfo(name='HB_Respiration_HKH', type='Respiration', channel_count=1,
                  nominal_srate=50,  # 假设呼吸带的采样率是50Hz
                  channel_format='int16',
                  source_id='HKH_Device')
channels = info.desc().append_child("channels")
ch = channels.append_child("channel")
ch.append_child_value("label", "BreathingWave")
ch.append_child_value("unit", "arbitrary_units")  # 可根据需求调整单位
# 创建LSL出口
outlet = StreamOutlet(info)

# =============================================================================
# 2. 串口和协议参数设置
# =============================================================================
# 从 COM3, COM5 找到端口
BAUD_RATE = 115200
CANDIDATE_PORTS = ['COM3', 'COM5']
COM_PORT = None  # 设备实际占用的COM端口号
for p in CANDIDATE_PORTS:
    try:
        ser = serial.Serial(p, BAUD_RATE, timeout=1)
        COM_PORT = p
        break
    except Exception:
        continue
if COM_PORT is None:
    print("错误：未能连接 COM3/COM5。请打开“设备管理器→端口（COM & LPT）”，"
          "查找呼吸带的端口号（HKH 端口为 Silicon Labs CP210x USB to UART Bridge），"
          "然后在代码里临时把 COM_PORT 改为实际端口后重试。")
    raise SystemExit(3)
# 如果上面成功打开了 ser，这里复用；如果需要统一打开逻辑，也可以先关闭再按原来流程重开


DEVICE_ID = 0xCC  # 呼吸带设备的ID
CMD_START = b'\xFF\xCC\x03\xA3\xA0'  # 启动命令
CMD_STOP = b'\xFF\xCC\x03\xA4\xA1'  # 停止命令

ser = None

# =============================================================================
# 3. 主程序
# =============================================================================

# 解析 --session
ap = argparse.ArgumentParser(add_help=False)
ap.add_argument("--session")
# 由hub控制打印
ap.add_argument("--under-hub", action="store_true")
# 由hub控制打印间隔
ap.add_argument("--hb-interval", type=float, default=2.0)
args, _ = ap.parse_known_args()

SESSION = args.session or time.strftime("S%Y%m%d-%H%M%S")
UNDER_HUB = args.under_hub
HB_EVERY = max(0.5, args.hb_interval)

# 注册信号
signal.signal(signal.SIGINT, _sig_handler)
signal.signal(signal.SIGTERM, _sig_handler)

# CSV文件名将包含时间戳
timestamp_str = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
out_dir = Path(RECORDER_DATA_DIR) / SESSION
out_dir.mkdir(parents=True, exist_ok=True)
csv_filename = str(out_dir / f"respiration_preview_{timestamp_str}.csv")

# 自动创建保存 CSV 文件的目录
csv_directory = os.path.dirname(csv_filename)  # 获取目录路径
if not os.path.exists(csv_directory):
    os.makedirs(csv_directory)  # 如果目录不存在，创建目录


try:
    # --- 交互与准备 ---
    print("--- 呼吸信号LSL采集脚本 ---")
    print(f"LSL Stream Name: {info.name()}")
    print(f"设备端口: {COM_PORT}")
    print("[READY] hkh")
    print("提示：在 Lab Recorder 勾选 HB_Respiration_HKH 流；按 ESC/Ctrl-C 可停止（从总线脚本更方便）。")

    print(f"数据将保存至: {csv_filename}")
    print("-----------------------------------")

    # --- 打开串口和文件 ---
    ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=1)
    print(f"成功连接到 {COM_PORT}。")
    
    with open(csv_filename, 'w', newline='') as csvfile:
        csv_writer = csv.writer(csvfile)
        csv_writer.writerow(['LSL_Timestamp', 'BreathingValue'])  # 写入表头

        # --- 发送启动命令 ---
        ser.write(CMD_START)
        # print("已发送启动命令... 开始记录数据。")
        print("按【ESC】键可随时停止录制。")
        print("-----------------------------------")
        
        start_time = pylsl.local_clock()
        last_print_time = start_time

        # --- 循环读取和处理数据 ---
        while not STOP_FLAG:
            if ser.in_waiting > 0 and ser.read(1) == b'\xFF':
                if ser.in_waiting > 0 and ser.read(1) == bytes([DEVICE_ID]):
                    packet_data = ser.read(5)
                    if len(packet_data) == 5:
                        hxh, hxl = packet_data[3], packet_data[4]
                        breathing_value = struct.unpack('>h', bytes([hxh, hxl]))[0]
                        
                        # 获取高精度时间戳并推送到LSL
                        lsl_timestamp = pylsl.local_clock()
                        outlet.push_sample([breathing_value], lsl_timestamp)
                        
                        # 写入CSV文件
                        csv_writer.writerow([lsl_timestamp, breathing_value])
                        
                        # --- 实时反馈 ---
                        current_time = lsl_timestamp
                        if current_time - last_print_time > 2.0:
                            elapsed_time = current_time - start_time
                            print(f"[HKH] 正在录制：累计 {elapsed_time:.1f}s，当前呼吸值 {breathing_value}")
                            last_print_time = current_time
        
        print("\n检测到【ESC】，正在停止...")

except serial.SerialException as e:
    print(f"\n错误: 无法打开端口 {COM_PORT}. 请检查设备连接或端口号。")
    print(e)
except Exception as e:
    print(f"\n发生未知错误: {e}")
finally:
    if ser and ser.is_open:
        ser.write(CMD_STOP)
        print("已发送停止命令。")
        ser.close()
        print(f"端口 {COM_PORT} 已关闭。数据已保存至 {csv_filename}。")
    else:
        print("程序结束。")
