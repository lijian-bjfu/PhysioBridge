import imp
import os
import serial
import time
import struct
import datetime
import csv
import keyboard  # 用于监听ESC键
import pylsl
from pylsl import StreamInfo, StreamOutlet

import sys
from pathlib import Path
# 获取当前工作目录
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)
# 从当前文件位置(utils)出发，向上走2层才能到达 PhysioBridge/ 根目录
project_root = Path(__file__).resolve().parent.parent
if str(project_root) not in sys.path:
    sys.path.insert(0, str(project_root))
# 从我们统一的路径管理器中导入所有需要的数据路径
from src.utils.paths import RECORDER_DATA_DIR

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

# CSV文件名将包含时间戳
timestamp_str = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
csv_filename = f"{RECORDER_DATA_DIR}/HKH/preview_{timestamp_str}.csv"

# =============================================================================
# 2. 串口和协议参数设置
# =============================================================================
COM_PORT = 'COM5'  # 设备实际占用的COM端口号
BAUD_RATE = 115200
DEVICE_ID = 0xCC  # 呼吸带设备的ID
CMD_START = b'\xFF\xCC\x03\xA3\xA0'  # 启动命令
CMD_STOP = b'\xFF\xCC\x03\xA4\xA1'  # 停止命令

ser = None

# =============================================================================
# 3. 主程序
# =============================================================================

# 生成 CSV 文件名的路径
timestamp_str = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
csv_filename = f"../data/recorder_data/HKH/preview_{timestamp_str}.csv"

# 自动创建保存 CSV 文件的目录
csv_directory = os.path.dirname(csv_filename)  # 获取目录路径
if not os.path.exists(csv_directory):
    os.makedirs(csv_directory)  # 如果目录不存在，创建目录

try:
    # --- 交互与准备 ---
    print("--- 呼吸信号LSL采集脚本 ---")
    print(f"LSL Stream Name: {info.name()}")
    print(f"设备端口: {COM_PORT}")
    print(f"数据将保存至: {csv_filename}")
    print("-----------------------------------")
    input("请戴好设备，确认连接后按【回车】开始...")

    # --- 打开串口和文件 ---
    ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=1)
    print(f"成功连接到 {COM_PORT}。")
    
    with open(csv_filename, 'w', newline='') as csvfile:
        csv_writer = csv.writer(csvfile)
        csv_writer.writerow(['LSL_Timestamp', 'BreathingValue'])  # 写入表头

        # --- 发送启动命令 ---
        ser.write(CMD_START)
        print("已发送启动命令... 开始记录数据。")
        print("按【ESC】键可随时停止录制。")
        print("-----------------------------------")
        
        start_time = pylsl.local_clock()
        last_print_time = start_time

        # --- 循环读取和处理数据 ---
        while not keyboard.is_pressed('esc'):
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
                            print(f"录制时间: {elapsed_time:.1f} 秒 | 当前呼吸值: {breathing_value}")
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
