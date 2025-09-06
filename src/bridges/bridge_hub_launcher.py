#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_acquisition.py
一键启动/监控/优雅停止：polar_bridge、hkh_bridge、lsl_mirror
- 生成统一 <SESSION> 目录名
- 打印本机 Wi-Fi IP，指导 Lab Recorder 操作
- 串流三子进程 stdout，2 秒节奏输出各自的人话状态
- 监听 ESC / Ctrl-C，发出优雅停止（SIGTERM），超时再强杀
"""

import os, sys, time, signal, threading, subprocess, queue, socket, hashlib, random
import json
from pathlib import Path
from typing import List
import argparse

# 统一从 paths 里拿目录（你已规划好的）
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)
from paths import RECORDER_DATA_DIR, MIRROR_DATA_DIR



# ---------- 小工具 ----------
def gen_session() -> str:
    ts = time.strftime("S%Y%m%d-%H%M%S")
    salt = hashlib.sha1(f"{ts}-{random.random()}".encode()).hexdigest()[:4]
    return f"{ts}-{salt}"

def local_wifi_ip() -> str:
    # UDP “假连”外网拿到出站网卡的本机 IP。失败时退回 127.0.0.1
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

class EscWatcher:
    """跨平台 ESC 监听。Windows 用 msvcrt，其它平台用终端非阻塞读；兜底用 Ctrl-C。"""
    def __init__(self):
        self._stop = threading.Event()
        self._th = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._th.start()

    def stop(self):
        self._stop.set()

    def _run(self):
        try:
            if os.name == "nt":
                import msvcrt
                while not self._stop.is_set():
                    if msvcrt.kbhit() and msvcrt.getch() == b"\x1b":
                        os.kill(os.getpid(), signal.SIGINT)
                        return
                    time.sleep(0.02)
            else:
                import sys, termios, tty, select
                fd = sys.stdin.fileno()
                old = termios.tcgetattr(fd)
                try:
                    tty.setcbreak(fd)
                    while not self._stop.is_set():
                        r, _, _ = select.select([sys.stdin], [], [], 0.05)
                        if r:
                            ch = os.read(fd, 1)
                            if ch == b"\x1b":
                                os.kill(os.getpid(), signal.SIGINT)
                                return
                finally:
                    termios.tcsetattr(fd, termios.TCSADRAIN, old)
        except Exception:
            # 控制台不可用/无 TTY 时，静默失败，用户可用 Ctrl-C
            pass

class Child:
    def __init__(self, name: str, cmd: List[str], cwd: Path):
        self.name = name
        self.cmd = cmd
        self.cwd = cwd
        self.proc: subprocess.Popen | None = None
        self.q = queue.Queue()
        self._reader = None
        self.ready = False

    def start(self):
        self.proc = subprocess.Popen(
            self.cmd,
            cwd=str(self.cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
            universal_newlines=True,
            encoding="utf-8",
            errors="replace"
        )
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()

    def _pump(self):
        assert self.proc and self.proc.stdout
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            # 检测 READY 信号
            if "[READY]" in line:
                self.ready = True
            self.q.put(line)

    def drain_lines(self) -> List[str]:
        lines = []
        try:
            while True:
                lines.append(self.q.get_nowait())
        except queue.Empty:
            pass
        return lines

    def term(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
            except Exception:
                pass

    def kill(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.kill()
            except Exception:
                pass

    def code(self) -> int | None:
        return self.proc.returncode if self.proc else None

def main():
    # argparse：加入 --interval
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=2.0, help="状态打印间隔（秒）")
    args = ap.parse_args()
    interval = max(0.5, args.interval)  # 下限保护

    here = Path(__file__).resolve().parent
    polar_py = here / "Polar" / "polar_bridge_batch.py"
    hkh_py   = here / "HKH-11C" / "hkh_bridge_batch.py"
    mirror_py= here / "Mirror" / "lsl_mirror_batch.py"

    session = gen_session()
    ip = local_wifi_ip()

    # 预创建目录
    Path(RECORDER_DATA_DIR, session).mkdir(parents=True, exist_ok=True)
    Path(RECORDER_DATA_DIR, "logs", session).mkdir(parents=True, exist_ok=True)
    Path(MIRROR_DATA_DIR, session).mkdir(parents=True, exist_ok=True)

    print("=" * 78)
    print("Physio Recording Suite — 一键采集")
    print(f"- 会话 ID: {session}")
    print(f"- 本机 Wi-Fi IP: {ip} ；手机端 UDP 目标请设为 {ip}:9001")
    print("- Lab Recorder 操作：打开后勾选 PB_* 数值流与 PB_UDP/PB_MARKERS，设置保存路径并点击 Start。")
    print("- 结束提示：按 ESC 或 Ctrl-C 结束，系统会先优雅收尾，再给出各文件位置。")
    print("=" * 78)

    # 子进程命令（统一传入 --session；mirror 指定 --out）
    py = sys.executable
    polar = Child("Polar",  [py, str(polar_py),  "--session", session, "--under-hub", "--hb-interval", str(interval)], here / "Polar")
    hkh   = Child("HKH",    [py, str(hkh_py),    "--session", session, "--under-hub", "--hb-interval", str(interval)], here / "HKH-11C")
    mirror= Child("Mirror", [py, str(mirror_py), "--session", session, "--out", str(MIRROR_DATA_DIR), "--under-hub", "--hb-interval", str(interval)], here / "Mirror")

    # 启动顺序：Polar -> HKH -> Mirror
    for c in (polar, hkh, mirror):
        c.start()

    # ESC 监听
    esc = EscWatcher(); esc.start()
    statuses = {}

    # 打印与监控主环
    last_flush = 0.0
    try:
        while True:
            # 实时转发子进程输出，加前缀
            for c in (polar, hkh, mirror):
                for line in c.drain_lines():
                    # 心跳 JSON 行：交给 hub 消化，不直接打印
                    if line.startswith("{") and '"hb"' in line:
                        try:
                            obj = json.loads(line)
                            # 把 obj 存起来供汇总（比如放到一个 dict: statuses[c.name] = obj）
                            statuses[c.name] = obj
                        except Exception:
                            pass
                        continue
                    # 其他关键事件行（READY/错误/警告等）照常打印
                    print(f"[{c.name}] {line}")


            # READY 检查
            if all(c.ready for c in (polar, hkh, mirror)):
                print("[Suite] 全部就绪，进入录制阶段。")

                # 打印一次 Lab Recorder 温馨确认（只打印一次）
                print("[Suite] 请确认 Lab Recorder 已开始录制。")

                # 防止重复刷屏
                for c in (polar, hkh, mirror):
                    c.ready = False  # 借位用作“已提示过”

            # 每 2 秒做一次健康检查（可拓展）
            now = time.time()
            if now - last_flush >= interval:
                # 这里根据 statuses 组成人话
                # Polar
                if "Polar" in statuses:
                    s = statuses["Polar"]
                    print(f"[hub] Polar：UDP包 {s.get('udp_pkts',0)} 丢 {s.get('udp_loss',0)} "
                        f"handled {s.get('handled',0)} unknown {s.get('unknown',0)} 延迟均值 {s.get('lat_avg_ms',0)}ms")
                # HKH
                if "HKH" in statuses:
                    s = statuses["HKH"]
                    print(f"[hub] HKH：累计 {s.get('elapsed_s',0):.1f}s，近{int(interval)}s样本 {s.get('recent_samples',0)}，最近值 {s.get('last_value','?')}")
                # Mirror
                if "Mirror" in statuses:
                    s = statuses["Mirror"]
                    print(f"[hub] Mirror：流 {s.get('streams',0)} 个，累计写入 {s.get('rows',0)} 行，最久空闲 {s.get('max_idle_s',0):.1f}s")

                last_flush = now


            # 子进程是否早退
            for c in (polar, hkh, mirror):
                if c.proc and c.proc.poll() is not None:
                    print(f"[Suite][警告] 进程 {c.name} 已退出，code={c.code()}")
                    # 直接进入收尾
                    raise KeyboardInterrupt

            time.sleep(0.05)
    except KeyboardInterrupt:
        print("\n[Suite] 收到停止请求，正在收尾...")
    finally:
        # 优雅终止
        for c in (polar, hkh, mirror):
            c.term()
        deadline = time.time() + 5.0
        while time.time() < deadline:
            alive = [c for c in (polar, hkh, mirror) if c.proc and c.proc.poll() is None]
            if not alive:
                break
            time.sleep(0.1)
        # 强杀兜底
        for c in (polar, hkh, mirror):
            c.kill()

        esc.stop()

        # 最终提示（你刚要求的 4 条）
        print("\n" + "=" * 78)
        print("录制已结束：")
        print("1) 您可以停止 Lab Recorder 的录制了，请到其“保存路径”查找主数据文件。")
        print(f"2) 网络记录日志保存在：{Path(RECORDER_DATA_DIR) / 'logs' / session}")
        print(f"3) 呼吸信号预览 CSV 在：{Path(RECORDER_DATA_DIR) / session}  下的  preview_*.csv")
        print(f"4) 镜像备份文件在：     {Path(MIRROR_DATA_DIR) / session}")
        print("=" * 78)


if __name__ == "__main__":
    main()
