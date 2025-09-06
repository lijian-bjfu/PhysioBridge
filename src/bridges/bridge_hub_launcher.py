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
import locale  # NEW

# 基于 __file__ 定位项目根：.../src/bridge/bridge_hub_launcher.py → 上两级就是 PhysioBridge/
HERE = Path(__file__).resolve()
PROJECT_ROOT = HERE.parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from paths import RECORDER_DATA_DIR, MIRROR_DATA_DIR


# ---------- 小工具 ----------
# 过滤 liblsl 的底层嘈杂日志（C++ 初始化吐的那些）
NOISY_MARKERS = ("netinterfaces.cpp", "api_config.cpp", "common.cpp", "udp_server.cpp")

# upd 丢包信息解码
def format_udp_loss(loss_obj) -> list[str]:
    """把 polar 心跳里的 udp_loss dict 格式化为多行中文人话。"""
    lines = []
    if not isinstance(loss_obj, dict):
        return lines
    for key, v in loss_obj.items():  # key 例：H10|rr / H10|hr ...
        pk = v.get("pkts", {})
        ia = v.get("ia_10s", {})  # 10 秒窗口即可
        recv = pk.get("recv", 0)
        miss = pk.get("miss", 0)
        ooo  = pk.get("ooo", 0)
        rate = ia.get("rate_hz", 0.0) or 0.0
        jit  = ia.get("jitter_ms", 0.0) or 0.0
        lr   = pk.get("loss_rate", 0.0) or 0.0
        lines.append(
            f"    {key}: 收 {recv} 丢 {miss} 乱序 {ooo} 丢率 {lr:.2%} 速率 {rate:.2f}Hz 抖动 {jit:.1f}ms"
        )
    return lines


# 噪音过滤与更宽容的心跳识别
def is_noisy_liblsl_line(s: str) -> bool:
    s = s.strip()
    if not s:
        return False
    # 只过滤 liblsl 初始化/网卡/多播绑定类的 INFO/WARN 行
    return any(m in s for m in NOISY_MARKERS)

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
                        # os.kill(os.getpid(), signal.SIGINT)
                        print("[hub] EscWatcher 捕获到 ESC，准备触发 SIGINT", flush=True)   # 诊断用
                        signal.raise_signal(signal.SIGINT)
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
                                # os.kill(os.getpid(), signal.SIGINT)
                                print("[hub] EscWatcher 捕获到 ESC，准备触发 SIGINT", flush=True)   # 诊断用
                                signal.raise_signal(signal.SIGINT)
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
        env = os.environ.copy()
        # 确保 PROJECT_ROOT 在 PYTHONPATH（你之前已加，无需改动就好）
        # env["PYTHONPATH"] = ...

        popen_kwargs = dict(
            cwd=str(self.cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
            universal_newlines=True,
            encoding=locale.getpreferredencoding(False),
            errors="replace",
            env=env,
        )
        if os.name == "nt":
            # Windows：建新进程组，便于发 CTRL_BREAK_EVENT
            popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            # POSIX：建新会话（相当于新进程组）
            popen_kwargs["preexec_fn"] = os.setsid

        self.proc = subprocess.Popen(self.cmd, **popen_kwargs)

        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()

    def soft_term(self):
        """平台感知的“软停”：Windows 发送 CTRL_BREAK；POSIX 对进程组发 SIGTERM。"""
        if not self.proc or self.proc.poll() is not None:
            return
        try:
            if os.name == "nt":
                self.proc.send_signal(signal.CTRL_BREAK_EVENT)
            else:
                # 给整个进程组发 SIGTERM
                os.killpg(self.proc.pid, signal.SIGTERM)
        except Exception as e:
            print(f"[hub] 向 {self.name} 发送软停失败：{e}", flush=True)


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
    # 全局停止标志
    hub_stop = {"v": False}
    def _hub_sigint(signum, frame):
        print("[hub] 主进程收到 SIGINT", flush=True)
        hub_stop["v"] = True
    signal.signal(signal.SIGINT, _hub_sigint)


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
            # 主循环 while True 内合适位置
            if hub_stop["v"]:
                raise KeyboardInterrupt  # 统一走到 except/ finally 停机路径

            # 实时转发子进程输出，加前缀
            for c in (polar, hkh, mirror):
                for raw in c.drain_lines():
                    line = raw.rstrip("\r\n")
                    # 1) 心跳识别：允许前导空白；解析 JSON 再判 hb 字段
                    ls = line.lstrip()
                    if ls.startswith("{"):
                        try:
                            obj = json.loads(ls)
                            if obj.get("hb") in {"polar","hkh","mirror"}:
                                statuses[c.name] = obj   # 2) 吃掉心跳，供汇总
                                continue
                        except Exception:
                            pass
                    # 3) 过滤 liblsl 底噪
                    if is_noisy_liblsl_line(line):
                        continue
                    # 其它关键事件照打
                    print(f"[{c.name}] {line}", flush=True)


            # READY 检查
            if all(c.ready for c in (polar, hkh, mirror)):
                # flush=True（避免被缓冲吞掉）
                print("[Suite] 全部就绪，进入录制阶段。", flush=True)
                print("[Suite] 请确认 Lab Recorder 已开始录制。", flush=True)

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
                    print(f"[hub] Polar：UDP包 {s.get('udp_pkts',0)} handled {s.get('handled',0)} unknown {s.get('unknown',0)} 延迟均值 {s.get('lat_avg_ms',0)}ms", flush=True)
                    for ln in format_udp_loss(s.get("udp_loss")):
                        print(f"[hub] {ln}", flush=True)
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
        print("\n[Suite] 收到停止请求，正在收尾...", flush=True)
  
    finally:
        # A) 广播“软停”信号：Win=CTRL_BREAK，POSIX=SIGTERM(进程组)
        print("[hub] 正在发送软停信号给子进程...", flush=True)
        for c in (polar, hkh, mirror):
            c.soft_term()  # 需要你已按前文添加 Child.soft_term()

        # B) 等待最多 5 秒让子进程自己收尾（HKH 发 STOP、关串口等）
        deadline = time.time() + 5.0
        while time.time() < deadline:
            alive = [c for c in (polar, hkh, mirror) if c.proc and c.proc.poll() is None]
            if not alive:
                break
            time.sleep(0.1)

        # C) 兜底强杀：还活着的才 kill（极少发生）
        for c in (polar, hkh, mirror):
            if c.proc and c.proc.poll() is None:
                print(f"[hub] {c.name} 未按时退出，执行强制结束", flush=True)
                c.kill()

        # C.1) 汇报各子进程停止状态
        for c in (polar, hkh, mirror):
            if c.proc is None:
                print(f"[hub] {c.name} 进程未启动", flush=True)
                continue
            rc = c.proc.poll()
            if rc is None:
                print(f"[hub] {c.name} 停止录制（强制结束）", flush=True)
            elif rc == 0:
                print(f"[hub] {c.name} 停止录制", flush=True)
            else:
                print(f"[hub] {c.name} 停止录制（退出码 {rc}）", flush=True)

        # D) 停止 ESC 监听，顺便吃掉子进程残留输出，避免把收尾提示顶掉
        try:
            esc.stop()
        except Exception:
            pass
        time.sleep(0.1)
        for c in (polar, hkh, mirror):
            _ = c.drain_lines()  # 不再打印，只是清空队列

        # E) 最终提示（全部 flush，确保可见）
        print("\n" + "=" * 78, flush=True)
        print("录制已结束：", flush=True)
        print("1) 您可以停止 Lab Recorder 的录制了，请到其“保存路径”查找主数据文件。", flush=True)
        print(f"2) 网络记录日志保存在：{Path(RECORDER_DATA_DIR) / 'logs' / session}", flush=True)
        print(f"3) 呼吸信号预览 CSV 在：{Path(RECORDER_DATA_DIR) / session} 下的 preview_*.csv", flush=True)
        print(f"4) 镜像备份文件在：     {Path(MIRROR_DATA_DIR) / session}", flush=True)
        print("=" * 78, flush=True)


if __name__ == "__main__":
    main()
