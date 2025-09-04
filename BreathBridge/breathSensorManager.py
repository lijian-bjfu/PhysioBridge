import serial
import csv
import time
import json
import os
from datetime import datetime
from serial import SerialException

class TelemetryPacket:
    def __init__(self, packet_type, device, t_device, seq=None):
        self.type = packet_type
        self.device = device
        self.t_device = t_device
        self.seq = seq

class BreathPacket(TelemetryPacket):
    def __init__(self, device, t_device, seq, breath_wave, frequency, amplitude):
        super().__init__('breath', device, t_device, seq)
        self.breath_wave = breath_wave
        self.frequency = frequency
        self.amplitude = amplitude

class BreathSensorManager:
    def __init__(self, port="COM5", baudrate=115200, timeout=1, retries=5, wait_time=2, debug_mode=False, udp_mode=False, udp_ip=None, udp_port=None):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self.device = "HKH-11C"
        self.debug_mode = debug_mode
        self.udp_mode = udp_mode
        self.udp_ip = udp_ip
        self.udp_port = udp_port
        self.seq = 0
        self.serial_conn = None

        # 尝试连接设备并处理端口占用问题
        self.connect_device(retries, wait_time)

    def connect_device(self, retries, wait_time):
        # 重试机制：尝试多次连接串口
        attempt = 0
        while attempt < retries:
            try:
                self.serial_conn = serial.Serial(self.port, self.baudrate, timeout=self.timeout)
                print(f"串口 {self.port} 连接成功！")
                return  # 成功连接，返回
            except SerialException as e:
                print(f"无法连接串口 {self.port}，错误: {e}")
                attempt += 1
                if attempt < retries:
                    print(f"重试 {attempt}/{retries}，等待 {wait_time} 秒后重试...")
                    time.sleep(wait_time)  # 等待后重试
                else:
                    print("无法打开串口，程序退出。")
                    exit()  # 失败后退出

    def read_data(self):
        # 模拟从设备读取数据的过程
        data = self.serial_conn.read(100)  # 假设读取100字节的数据
        if data:
            # 解析数据，假设返回的是呼吸波形数据（这里简单模拟）
            breath_wave = [int(i) for i in data]  # 只是简单的转化为整数列表
            frequency = 0.2  # 假设频率
            amplitude = 0.5  # 假设幅度

            # 时间戳，使用当前时间
            t_device = time.time()

            # 生成 Telemetry 数据包
            packet = BreathPacket(self.device, t_device, self.seq, breath_wave, frequency, amplitude)
            self.seq += 1

            # 返回生成的数据包
            return packet
        return None

    def save_csv(self, packet):
        # 创建文件夹路径
        save_directory = "BreathData/"
        if not os.path.exists(save_directory):
            os.makedirs(save_directory)

        filename = f"{save_directory}BreathData_{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.csv"
        with open(filename, mode='w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(["timestamp", "breath_wave", "frequency", "amplitude"])
            writer.writerow([packet.t_device, packet.breath_wave, packet.frequency, packet.amplitude])

    def run(self):
        print("按回车开始录制数据，按 Esc 键结束")
        input()  # 等待用户按下回车键开始

        start_time = time.time()
        print(f"开始录制数据...")

        try:
            while True:
                packet = self.read_data()
                if packet:
                    # 每 2 秒打印一次数据
                    elapsed_time = time.time() - start_time
                    if elapsed_time >= 2:
                        print(f"时间: {elapsed_time:.2f}s, 呼吸频率: {packet.frequency} Hz, 呼吸幅度: {packet.amplitude}")
                        start_time = time.time()  # 重置计时器

                    if self.debug_mode:
                        self.save_csv(packet)

                time.sleep(0.02)  # 模拟 20 毫秒的数据间隔

        except KeyboardInterrupt:
            print("\n结束录制，保存数据。")

# 示例：如何使用 BreathSensorManager
if __name__ == "__main__":
    manager = BreathSensorManager(debug_mode=True)
    manager.run()
