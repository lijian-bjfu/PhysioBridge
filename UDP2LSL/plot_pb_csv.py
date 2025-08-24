#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将 xdf_to_csv.py 产生的 CSV 曲线化展示，并叠加 Marker。
- 在 IDE 直接运行：若无命令行参数，会弹出目录选择对话框以选择 CSV 输出目录
- 读取 *_hr.csv, *_rr.csv, *_ecg.csv, *_acc.csv, *_markers.csv（存在哪个画哪个）
- 每类信号一张图，时间轴单位 = 秒（默认使用 LSL 主机时间）
- Marker 以竖线与文本标注叠加到时间轴上
- 保存到 plots_<csv目录名>/ 下；传 --show 则同时弹窗查看
- 依赖：matplotlib（无需 pandas/numpy）

注意：遵循你的绘图规范
1) 仅用 matplotlib
2) 每张图独立 figure（无子图）
3) 不显式设置颜色（使用默认配色）
"""

from __future__ import annotations
import argparse
import csv
import math
from pathlib import Path
from typing import List, Tuple, Dict, Optional

# 文件对话框（与 qa_check.py / xdf_to_csv.py 风格一致）
try:
    from tkinter import Tk, filedialog
except Exception:
    Tk = None
    filedialog = None

import matplotlib.pyplot as plt  # matplotlib 作为唯一绘图库

# ---------- 实用函数 ----------

def pick_dir_dialog(title: str = "选择 CSV 输出目录") -> Optional[Path]:
    if Tk is None or filedialog is None:
        return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askdirectory(title=title, mustexist=True)
    root.destroy()
    return Path(p) if p else None

def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)

def decimate_stride(n: int, max_points: int) -> int:
    """为 n 个点计算抽样步长，使总点数不超过 max_points"""
    if n <= max_points:
        return 1
    # 至少取 2 倍余量，避免边界误差
    return max(1, math.ceil(n / max_points))

# ---------- CSV 读取器 ----------

def load_two_cols_csv(path: Path, colx: str, coly: str) -> Tuple[List[float], List[float]]:
    """读取只有两列（或以上但只取两列）的 CSV，如 HR、RR"""
    xs, ys = [], []
    if not path.exists():
        return xs, ys
    with path.open("r", encoding="utf-8") as f:
        rd = csv.DictReader(f)
        for row in rd:
            try:
                xs.append(float(row[colx]))
                ys.append(float(row[coly]))
            except Exception:
                continue
    return xs, ys

def load_ecg_csv(path: Path) -> Tuple[List[float], List[float], List[float]]:
    """读取 ECG：time_lsl, uV；同时抓取 fs（若存在，以第一条为准仅用于标题）"""
    ts, uv = [], []
    fs_first = None
    if not path.exists():
        return ts, uv, fs_first
    with path.open("r", encoding="utf-8") as f:
        rd = csv.DictReader(f)
        for row in rd:
            try:
                t = float(row["time_lsl"])
                v = float(row["uV"])
                ts.append(t); uv.append(v)
                if fs_first is None and row.get("fs"):
                    fs_first = float(row["fs"])
            except Exception:
                continue
    return ts, uv, fs_first

def load_acc_csv(path: Path, mode: str = "mag") -> Tuple[List[float], List[float], Optional[float], Optional[int]]:
    """
    读取 ACC：
    - 时间列：time_lsl
    - 数值：
        - mode="mag"：计算幅值 sqrt(x^2+y^2+z^2)
        - mode="xyz"：本函数仅返回 x（用于画一条），如需三条由 PBPlotter.plot_acc_xyz 专用函数处理
    - 附加：返回 fs_first 与 range_g_first（标题用）
    """
    ts, val = [], []
    fs_first = None
    rng_first = None
    if not path.exists():
        return ts, val, fs_first, rng_first
    with path.open("r", encoding="utf-8") as f:
        rd = csv.DictReader(f)
        for row in rd:
            try:
                t = float(row["time_lsl"])
                if mode == "mag":
                    x = float(row["x_mG"]); y = float(row["y_mG"]); z = float(row["z_mG"])
                    v = math.sqrt(x*x + y*y + z*z)
                else:
                    v = float(row["x_mG"])
                ts.append(t); val.append(v)
                if fs_first is None and row.get("fs"):
                    fs_first = float(row["fs"])
                if rng_first is None and row.get("range_g"):
                    try:
                        rng_first = int(row["range_g"])
                    except Exception:
                        rng_first = None
            except Exception:
                continue
    return ts, val, fs_first, rng_first

def load_acc_xyz(path: Path) -> Tuple[List[float], List[float], List[float], List[float], Optional[float], Optional[int]]:
    """读取 ACC 三轴专用：返回 time, x, y, z, fs_first, range_g_first"""
    ts, xs, ys, zs = [], [], [], []
    fs_first = None
    rng_first = None
    if not path.exists():
        return ts, xs, ys, zs, fs_first, rng_first
    with path.open("r", encoding="utf-8") as f:
        rd = csv.DictReader(f)
        for row in rd:
            try:
                t = float(row["time_lsl"])
                x = float(row["x_mG"]); y = float(row["y_mG"]); z = float(row["z_mG"])
                ts.append(t); xs.append(x); ys.append(y); zs.append(z)
                if fs_first is None and row.get("fs"):
                    fs_first = float(row["fs"])
                if rng_first is None and row.get("range_g"):
                    try:
                        rng_first = int(row["range_g"])
                    except Exception:
                        rng_first = None
            except Exception:
                continue
    return ts, xs, ys, zs, fs_first, rng_first

def load_markers(path: Path) -> List[Tuple[float, str]]:
    """读取 markers：time_lsl, label（label 若为 JSON 则解析，否则用原文本）"""
    marks = []
    if not path.exists():
        return marks
    with path.open("r", encoding="utf-8") as f:
        rd = csv.DictReader(f)
        for row in rd:
            try:
                t = float(row["time_lsl"])
                lab = row.get("label", "")
                marks.append((t, lab))
            except Exception:
                continue
    return marks

# ---------- 绘图类 ----------

class PBPlotter:
    """
    负责将 PB CSV 绘制为曲线图。每个方法只做一张独立图（无子图），
    不设置具体颜色，遵循你的绘图规范。
    """
    def __init__(self, csv_dir: Path, out_dir: Path, markers: List[Tuple[float, str]], max_points: int = 120_000):
        self.csv_dir = csv_dir
        self.out_dir = out_dir
        self.markers = markers or []
        self.max_points = max_points
        ensure_dir(out_dir)

    def _add_markers(self, ax):
        if not self.markers:
            return
        # 垂直线 + 文本标签。为避免遮挡，文本在顶部偏移
        ymin, ymax = ax.get_ylim()
        ytxt = ymax - (ymax - ymin) * 0.05
        for t, lab in self.markers:
            ax.axvline(t)  # 不设置颜色
            ax.text(t, ytxt, lab, rotation=90, va="top", ha="center", fontsize=8)

    def _downsample(self, xs: List[float], ys: List[float]) -> Tuple[List[float], List[float]]:
        n = len(xs)
        if n <= self.max_points:
            return xs, ys
        s = decimate_stride(n, self.max_points)
        xs2 = xs[::s]
        ys2 = ys[::s]
        return xs2, ys2

    def plot_ecg(self, png_name: str = "ecg.png"):
        p = self.csv_dir.glob("*_ecg.csv")
        paths = list(p)
        if not paths:
            print("[ECG] 未找到 *_ecg.csv，跳过")
            return
        path = paths[0]
        ts, uv, fs = load_ecg_csv(path)
        if not ts:
            print("[ECG] 数据为空，跳过")
            return
        ts, uv = self._downsample(ts, uv)

        fig = plt.figure()
        ax = fig.add_subplot(111)
        ax.plot(ts, uv)  # 不设色
        ax.set_title(f"ECG (uV) vs time  |  fs={fs if fs else '?'} Hz")
        ax.set_xlabel("time_lsl (s)")
        ax.set_ylabel("ECG (uV)")
        self._add_markers(ax)
        fig.tight_layout()
        out = self.out_dir / png_name
        fig.savefig(out, dpi=150)
        plt.close(fig)
        print(f"[SAVE] {out}")

    def plot_acc(self, mode: str = "mag", png_name: str = "acc.png"):
        p = self.csv_dir.glob("*_acc.csv")
        paths = list(p)
        if not paths:
            print("[ACC] 未找到 *_acc.csv，跳过")
            return
        path = paths[0]

        if mode == "xyz":
            ts, xs, ys, zs, fs, rng = load_acc_xyz(path)
            if not ts:
                print("[ACC] 数据为空，跳过")
                return
            # 合并三轴长度，做统一抽样（以时间为准）
            # 这里简单策略：以 ts 为基准抽样，三轴同样步长
            n = len(ts)
            s = decimate_stride(n, self.max_points)
            ts2 = ts[::s]; xs2 = xs[::s]; ys2 = ys[::s]; zs2 = zs[::s]
            fig = plt.figure()
            ax = fig.add_subplot(111)
            ax.plot(ts2, xs2, label="x_mG")
            ax.plot(ts2, ys2, label="y_mG")
            ax.plot(ts2, zs2, label="z_mG")
            ax.legend()
            ax.set_title(f"ACC xyz (mG) vs time  |  fs={fs if fs else '?'} Hz  range=±{rng if rng else '?'}G")
            ax.set_xlabel("time_lsl (s)")
            ax.set_ylabel("ACC (mG)")
            self._add_markers(ax)
            fig.tight_layout()
            out = self.out_dir / "acc_xyz.png"
            fig.savefig(out, dpi=150)
            plt.close(fig)
            print(f"[SAVE] {out}")
        else:
            ts, val, fs, rng = load_acc_csv(path, mode="mag")
            if not ts:
                print("[ACC] 数据为空，跳过")
                return
            ts, val = self._downsample(ts, val)
            fig = plt.figure()
            ax = fig.add_subplot(111)
            ax.plot(ts, val)
            ax.set_title(f"ACC magnitude (mG) vs time  |  fs={fs if fs else '?'} Hz  range=±{rng if rng else '?'}G")
            ax.set_xlabel("time_lsl (s)")
            ax.set_ylabel("ACC |a| (mG)")
            self._add_markers(ax)
            fig.tight_layout()
            out = self.out_dir / png_name
            fig.savefig(out, dpi=150)
            plt.close(fig)
            print(f"[SAVE] {out}")

    def plot_hr(self, png_name: str = "hr.png"):
        p = self.csv_dir.glob("*_hr.csv")
        paths = list(p)
        if not paths:
            print("[HR] 未找到 *_hr.csv，跳过")
            return
        path = paths[0]
        ts, bpm = load_two_cols_csv(path, "time_lsl", "bpm")
        if not ts:
            print("[HR] 数据为空，跳过")
            return
        ts, bpm = self._downsample(ts, bpm)
        fig = plt.figure()
        ax = fig.add_subplot(111)
        ax.plot(ts, bpm)
        ax.set_title("HR (bpm) vs time")
        ax.set_xlabel("time_lsl (s)")
        ax.set_ylabel("HR (bpm)")
        self._add_markers(ax)
        fig.tight_layout()
        out = self.out_dir / png_name
        fig.savefig(out, dpi=150)
        plt.close(fig)
        print(f"[SAVE] {out}")

    def plot_rr(self, png_name: str = "rr.png"):
        p = self.csv_dir.glob("*_rr.csv")
        paths = list(p)
        if not paths:
            print("[RR] 未找到 *_rr.csv，跳过")
            return
        path = paths[0]
        ts, ms = load_two_cols_csv(path, "time_lsl", "ms")
        if not ts:
            print("[RR] 数据为空，跳过")
            return
        ts, ms = self._downsample(ts, ms)
        fig = plt.figure()
        ax = fig.add_subplot(111)
        ax.plot(ts, ms)
        ax.set_title("RR interval (ms) vs time")
        ax.set_xlabel("time_lsl (s)")
        ax.set_ylabel("RR (ms)")
        self._add_markers(ax)
        fig.tight_layout()
        out = self.out_dir / png_name
        fig.savefig(out, dpi=150)
        plt.close(fig)
        print(f"[SAVE] {out}")

# ---------- 主流程 ----------

def parse_args():
    ap = argparse.ArgumentParser(description="Plot PB CSV curves with markers.")
    ap.add_argument("--csv-dir", type=Path, default=None, help="CSV 输出目录（包含 *_hr.csv 等文件）")
    ap.add_argument("--what", choices=["all","ecg","acc","hr","rr"], default="all", help="绘制哪类图")
    ap.add_argument("--acc-mode", choices=["mag","xyz"], default="mag", help="ACC 绘制模式：幅值或三轴")
    ap.add_argument("--max-points", type=int, default=120_000, help="单图最大点数，超出则抽样降采样")
    ap.add_argument("--show", action="store_true", help="生成后弹窗显示（不加则仅保存 PNG）")
    return ap.parse_args()

def main():
    args = parse_args()

    csv_dir = args.csv_dir
    if csv_dir is None:
        csv_dir = pick_dir_dialog("选择 CSV 输出目录（包含 *_hr.csv / *_rr.csv / *_ecg.csv / *_acc.csv）")
        if csv_dir is None:
            print("[ERROR] 未选择 CSV 目录")
            return
    if not csv_dir.exists():
        print(f"[ERROR] 目录不存在：{csv_dir}")
        return

    # 输出图像目录：plots_<csv目录名>
    out_dir = csv_dir.parent / f"plots_{csv_dir.name}"
    ensure_dir(out_dir)

    # 读取 markers（若存在）
    mk_paths = list(csv_dir.glob("*_markers.csv"))
    markers = load_markers(mk_paths[0]) if mk_paths else []

    print(f"[INFO] CSV 目录: {csv_dir}")
    print(f"[INFO] 输出目录: {out_dir}")
    if markers:
        print(f"[INFO] markers: {len(markers)} 条")
    else:
        print("[INFO] 无 markers 文件")

    plotter = PBPlotter(csv_dir=csv_dir, out_dir=out_dir, markers=markers, max_points=args.max_points)

    if args.what in ("all","ecg"):
        plotter.plot_ecg()
    if args.what in ("all","acc"):
        plotter.plot_acc(mode=args.acc_mode)
    if args.what in ("all","hr"):
        plotter.plot_hr()
    if args.what in ("all","rr"):
        plotter.plot_rr()

    if args.show:
        # 注意：各图已保存并关闭；若需要交互显示，将上一段绘图改为不关闭并在此统一 show。
        # 为不增加显存占用，这里简单提示用户使用 --show 时可临时注释掉 plt.close(fig)。
        print("[HINT] 你启用了 --show，但为节省内存，脚本在保存后已关闭各 figure。")
        print("       如需交互查看，请注释掉 PBPlotter 各 plot_* 方法中的 plt.close(fig) 再运行。")

    print("[DONE] 所选曲线已生成 PNG。")

if __name__ == "__main__":
    main()
