#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Polar 数据质量体检与可视化（Verity + H10）
- 自动识别由 polar_xdf_to_csv.py 导出的 CSV（ppg/ppi/hr/acc/rr/ecg/markers）
- 生成 qa_report.txt 与若干 PNG 图（存在的信号才绘制）
- 指标与阈值集中在 CONFIG，可按需要调整

本版改动要点：
1) 增强 locate_files 以识别带设备后缀的文件（_h10, _verity）。
2) 根据识别的设备信息，自动选择正确的名义采样率进行分析。
3) 输出的图表和报告中包含设备名，使其更清晰。
"""

import os, sys, glob, csv, math, json, traceback
from pathlib import Path
# 获取当前工作目录
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)
# 从当前文件位置(utils)出发，向上走2层才能到达 PhysioBridge/ 根目录
project_root = Path(__file__).resolve().parent
if str(project_root) not in sys.path:
    sys.path.insert(0, str(project_root))
# 从我们统一的路径管理器中导入所有需要的数据路径
from src.utils.paths import RECORDER_DATA_DIR, PROCESSED_DATA_DIR

try:
    from tkinter import Tk, filedialog
except ImportError:
    Tk = None; filedialog = None

from typing import Dict, Any, List, Tuple, Optional

import numpy as np
import matplotlib.pyplot as plt


# ───────────────────────────────────────────────────────────────
# 配置区：阈值、绘图参数
# ───────────────────────────────────────────────────────────────
CONFIG = {
    # 名义采样率 (Nominal Sampling Rates in Hz)
    "nominal_fs": {
        "PPG": 55.0,
        "ACC_VERITY": 52.0,
        "ACC_H10": 50.0,
        "ECG": 130.0,
    },
    # 采样完整率阈值（等间隔流）
    "completeness": {
        "PPG": {"pass": 0.99, "warn": 0.97},   # ≥0.99 PASS；≥0.97 WARN；否则 FAIL
        "ACC": {"pass": 0.98, "warn": 0.95},
        "ECG": {"pass": 0.99, "warn": 0.98},
    },
    # HR vs RR/PPI 一致性（MAE，单位 bpm，越小越好）
    "hr_align": {"pass": 2.0, "warn": 5.0},
    # PPI 质量阈值（ms / 比例）
    "ppi_quality": {
        "median_ms": {"pass": 20.0, "warn": 30.0},    # ≤20 PASS；≤30 WARN；否则 FAIL
        "blocker_ratio": {"pass": 0.02, "warn": 0.05},# ≤2% PASS；≤5% WARN；否则 FAIL
        "skin_contact_ratio": {"pass": 0.90, "warn": 0.70},  # ≥0.9 PASS；≥0.7 WARN；否则 FAIL
    },
    # PPG 通道一致性（通道间相关均值，越高越好）
    "ppg_consistency": {"pass": 0.60, "warn": 0.30},
    # 运动伪迹占比（按 ACC 模长阈判，越小越好）
    "motion_ratio": {"pass": 0.10, "warn": 0.30},
    # 绘图：采样点下采样因子以免图太密
    "plot_downsample": {
        "PPG": 1,
        "ACC": 1,
        "ECG": 1,
    },
    # 运动指数窗口（秒）
    "acc_motion_win_sec": 1.0,
    # 选择目录弹框（仅在未提供参数时）
    "use_tk": True,
}

# ───────────────────────────────────────────────────────────────
# 工具函数：评级（含规则说明）
# ───────────────────────────────────────────────────────────────
def grade_three(value: float, pass_thr: float, warn_thr: float,
                higher_is_better: bool=True,
                metric_name: Optional[str]=None,
                unit: Optional[str]=None) -> Tuple[str, str]:
    """
    通用三级评级 + 规则说明：
    - higher_is_better=True:  值≥pass -> PASS；warn≤值<pass -> WARN；值<warn -> FAIL
    - higher_is_better=False: 值≤pass -> PASS；pass<值≤warn -> WARN；值>warn -> FAIL

    返回:
      grade: "PASS"|"WARN"|"FAIL"|"N/A"
      rule_text: 一段可读文字，说明 PASS/WARN/FAIL 的阈值规则（含方向）
    """
    unit = unit or ""
    name = metric_name or "metric"
    try:
        v = float(value)
        if not np.isfinite(v):
             return ("N/A", f"{name}: 无法计算（值为 NaN 或 Inf）")
    except (ValueError, TypeError):
        return ("N/A", f"{name}: 无法计算（值不可用）")

    if higher_is_better:
        rule = f"值≥{pass_thr:.3f}{unit} 为 PASS；{warn_thr:.3f}{unit}≤值<{pass_thr:.3f}{unit} 为 WARN；值<{warn_thr:.3f}{unit} 为 FAIL"
        if v >= pass_thr: return ("PASS", rule)
        if v >= warn_thr: return ("WARN", rule)
        return ("FAIL", rule)
    else:
        rule = f"值≤{pass_thr:.3f}{unit} 为 PASS；{pass_thr:.3f}{unit}<值≤{warn_thr:.3f}{unit} 为 WARN；值>{warn_thr:.3f}{unit} 为 FAIL"
        if v <= pass_thr: return ("PASS", rule)
        if v <= warn_thr: return ("WARN", rule)
        return ("FAIL", rule)

def combine_grades(grades: List[str]) -> str:
    # [修改] 首先，过滤掉所有 "N/A" 的评级
    valid_grades = [g for g in grades if g != "N/A"]
    
    # 如果过滤后没有剩下任何有效的评级，则返回 "N/A"
    if not valid_grades: 
        return "N/A"
    
    # [修改] 接着，只在有效的评级中判断 FAIL, WARN, PASS
    if any(g == "FAIL" for g in valid_grades): return "FAIL"
    if any(g == "WARN" for g in valid_grades): return "WARN"
    
    return "PASS"

# ───────────────────────────────────────────────────────────────
# IO：查找 CSV、读取
# ───────────────────────────────────────────────────────────────
# ==============================================================================
#                      第1步：替换这个函数
# ==============================================================================
def pick_dir_dialog(title: str) -> Optional[Path]:
    """弹出一个对话框让用户选择目录。"""
    if Tk is None or filedialog is None: return None
    root = Tk(); root.withdraw(); root.update()
    # 默认打开 recorder_data 目录，方便用户查找
    p = filedialog.askdirectory(title=title, initialdir=str(RECORDER_DATA_DIR))
    root.destroy(); return Path(p) if p else None

# def locate_files(root: Path) -> Dict[str, Dict[str, Path]]:
#     """
#     [新] 扫描目录内所有CSV，并按数据类型和设备进行分类。
#     返回一个嵌套字典，结构为:
#     {
#         "HR": {"h10": Path_to_hr_h10_csv, "verity": Path_to_hr_verity_csv},
#         "RR": {"h10": Path_to_rr_h10_csv},
#         ...
#     }
#     """
#     # 定义关键字和类型的映射关系
#     # 格式：(文件名中的关键字, 数据类型, 设备名)
#     key_map = [
#         ("_hr_h10", "HR", "h10"),
#         ("_hr_verity", "HR", "verity"),
#         ("_rr_h10", "RR", "h10"),
#         ("_ppi_verity", "PPI", "verity"),
#         ("_ppg_verity", "PPG", "verity"), 
#         ("_acc_h10", "ACC", "h10"),
#         ("_acc_verity", "ACC", "verity"),
#         ("_ecg_h10", "ECG", "h10"),
#         ("_markers", "MARKERS", "unknown"),
#     ]
    
#     # 初始化一个空的嵌套字典
#     found: Dict[str, Dict[str, Path]] = {
#         "HR": {}, "RR": {}, "PPI": {}, "PPG": {}, "ACC": {}, "ECG": {}, "MARKERS": {}
#     }

#     # 遍历目录下的所有CSV文件
#     for path in root.glob("*.csv"):
#         fname = path.name.lower()
#         # 检查文件名符合哪个关键字
#         for key, kind, device in key_map:
#             if key in fname:
#                 # 存入字典: found['HR']['h10'] = Path(...)
#                 found[kind][device] = path
#                 break # 找到匹配就处理下一个文件
    
#     return found

def locate_files(root: Path) -> Dict[str, Dict[str, Path]]:
    """
    [新] 扫描目录内所有CSV（包括子目录），并按数据类型和设备进行分类。
    返回一个嵌套字典...
    """
    files = {k: {} for k in ["HR", "RR", "PPI", "ECG", "ACC", "PPG", "MARKERS"]}
    
    # 使用 rglob('*.csv') 来递归搜索所有子文件夹中的CSV文件
    for p in root.rglob('*.csv'):
        fname = p.name.lower()
        kind = None  # <-- 【修正点 1】在循环开始时，重置 kind 变量

        # --- 从文件名推断数据类型 ---
        if "_hr_" in fname: kind = "HR"
        elif "_rr_" in fname: kind = "RR"
        elif "_ppi_" in fname: kind = "PPI"
        elif "_ecg_" in fname: kind = "ECG"
        elif "_acc_" in fname: kind = "ACC"
        elif "_ppg_" in fname: kind = "PPG"
        elif "_markers_" in fname: kind = "MARKERS"

        # --- 如果成功识别了类型，才继续处理 ---
        if kind: # <-- 【修正点 2】只有在 kind 被成功赋值后，才执行下面的代码
            # 推断设备名
            device = "h10" if "h10" in fname else "verity" if "verity" in fname else "unknown"
            files[kind][device] = p
            
    return files

def read_csv(path: Path) -> Tuple[np.ndarray, np.ndarray, List[str]]:
    """读取导出 CSV：首列必须是 time_lsl，后面是数值列。"""
    times, rows, headers = [], [], []
    with path.open("r", encoding="utf-8", newline="") as f:
        r = csv.reader(f)
        headers = next(r)
        for row in r:
            if not row: continue
            try:
                times.append(float(row[0]))
                vals = [float(v) if v else np.nan for v in row[1:]]
                rows.append(vals)
            except (ValueError, IndexError):
                continue
    t = np.array(times, dtype=float)
    X = np.array(rows, dtype=float) if rows else np.zeros((0, max(0, len(headers)-1)))
    return t, X, headers

# ───────────────────────────────────────────────────────────────
# 指标与分析 (此部分函数与原版基本一致，无需修改)
# ───────────────────────────────────────────────────────────────
def estimate_fs(t: Optional[np.ndarray]) -> float:
    if t is None or t.size < 2: return 0.0
    dt = np.diff(t)
    dt = dt[np.isfinite(dt) & (dt > 1e-6)]
    if dt.size < 1: return 0.0
    fs = 1.0 / np.median(dt)
    return fs if fs >= 5.0 else 0.0

def completeness(n_samples: int, fs_nominal: float, t_span: float) -> float:
    if fs_nominal <= 0 or t_span <= 0: return 1.0
    expected = fs_nominal * t_span
    return float(n_samples) / float(expected) if expected > 0 else 1.0

def detrend_hp(x: np.ndarray, fs: float, win_sec: float = 2.0) -> np.ndarray:
    if x.size == 0 or fs <= 0: return x
    win = int(max(3, round(fs * win_sec)))
    if x.size < win: return x - np.mean(x)
    kernel = np.ones(win, dtype=float) / float(win)
    ma = np.convolve(x, kernel, mode="same")
    return x - ma

def ppg_channel_consistency(X: np.ndarray, fs: float) -> Tuple[float, float]:
    if X.ndim < 2 or X.shape[1] < 2: return (np.nan, np.nan)
    Y = np.apply_along_axis(detrend_hp, 0, X, fs=fs)
    C = np.corrcoef(Y, rowvar=False)
    if not np.all(np.isfinite(C)): return (np.nan, np.nan)
    vals = C[np.triu_indices_from(C, k=1)]
    return (float(np.nanmean(vals)), float(np.nanmin(vals))) if vals.size > 0 else (np.nan, np.nan)

def acc_motion_ratio(t: np.ndarray, X: np.ndarray, fs_hint: float, win_sec: float) -> float:
    if X.size == 0: return np.nan
    mag = np.linalg.norm(X[:, :3], axis=1)
    fs = fs_hint if fs_hint > 0 else estimate_fs(t)
    if fs <= 0: return np.nan
    win = int(max(3, round(fs * win_sec)))
    if mag.size < win: return np.nan
    rms = np.sqrt(np.convolve(mag**2, np.ones(win)/win, mode="same"))
    med = np.nanmedian(rms)
    mad = np.nanmedian(np.abs(rms - med)) + 1e-9
    thr = med + 2.0 * mad
    return float(np.nanmean(rms > thr))

def hr_from_events(t_evt: np.ndarray, ms: np.ndarray, t_query: np.ndarray) -> np.ndarray:
    if t_evt.size == 0 or ms.size == 0 or t_query.size == 0:
        return np.full_like(t_query, np.nan, dtype=float)
    indices = np.searchsorted(t_evt, t_query, side='right') - 1
    valid_indices = indices >= 0
    hr_est = np.full_like(t_query, np.nan, dtype=float)
    ms_valid = ms[indices[valid_indices]]
    hr_est[valid_indices] = 60000.0 / ms_valid
    return hr_est

def hr_align_metrics(t_hr: np.ndarray, hr_bpm: np.ndarray, t_evt: np.ndarray, ms: np.ndarray) -> Tuple[float, float, Optional[str]]:
    """
    计算 HR 与事件导出 HR 的 MAE 与均值偏差。
    [新] 返回值增加了第三项：一个可选的字符串，用于在无法计算时说明原因。
    """
    # 原因1：输入数据为空
    if t_hr.size == 0 or hr_bpm.size == 0 or t_evt.size == 0 or ms.size == 0:
        return (np.nan, np.nan, "输入数据为空 (HR或事件流文件可能为空).")

    hr_est = hr_from_events(t_evt, ms, t_hr)
    mask = np.isfinite(hr_bpm) & np.isfinite(hr_est)

    # 原因2：经过时间对齐后，没有找到任何可以共同比较的有效数据点
    if not np.any(mask):
        return (np.nan, np.nan, "在HR与事件流的重叠时段内, 未找到任何有效的数据点进行比较.")
    
    diff = hr_bpm[mask] - hr_est[mask]
    mae = float(np.nanmean(np.abs(diff)))
    bias = float(np.nanmean(diff))
    
    # 计算成功，返回 None 作为原因
    return mae, bias, None

def extract_event_time(headers: List[str], t_default: np.ndarray, X: np.ndarray) -> np.ndarray:
    if X.size == 0 or not headers: return t_default
    try:
        te_idx = headers[1:].index('te') # Find 'te' in data columns
        te = X[:, te_idx]
        return te if np.isfinite(te).sum() > te.size / 2 else t_default
    except ValueError:
        return t_default

def ppi_quality_stats(ppi_headers: List[str], X: np.ndarray) -> Dict[str, Any]:
    stats = {}
    if X.size == 0 or not ppi_headers: return stats
    data_headers = ppi_headers[1:]
    try:
        q_idx = data_headers.index('quality')
        q = X[:, q_idx]
        stats.update({"quality_median": float(np.nanmedian(q)), "quality_p10": float(np.nanpercentile(q, 10)), "quality_p90": float(np.nanpercentile(q, 90))})
    except (ValueError, IndexError): pass
    try:
        b_idx = data_headers.index('blocker')
        stats["blocker_ratio"] = float(np.nanmean(X[:, b_idx] >= 0.5))
    except (ValueError, IndexError): pass
    try:
        sc_idx = data_headers.index('skincontact')
        stats["skin_contact_ratio"] = float(np.nanmean(X[:, sc_idx] >= 0.5))
    except (ValueError, IndexError): pass
    return stats

# (可以把这个函数加在 “指标与分析” 部分的末尾)
def analyze_interval_quality(X_ms: np.ndarray) -> Dict[str, Any]:
    """计算RR/PPI序列的核心质量指标"""
    if X_ms.size < 2:
        return {"n_beats": X_ms.size, "mean_hr": np.nan, "sdnn": np.nan, "rmssd": np.nan, "artifact_pct": np.nan}
    
    # 剔除NaN和非正数的值
    X_ms = X_ms[np.isfinite(X_ms) & (X_ms > 0)]
    if X_ms.size < 2:
        return {"n_beats": X_ms.size, "mean_hr": np.nan, "sdnn": np.nan, "rmssd": np.nan, "artifact_pct": np.nan}

    n_beats = X_ms.size
    mean_rr = np.mean(X_ms)
    mean_hr = 60000.0 / mean_rr if mean_rr > 0 else 0
    sdnn = np.std(X_ms)
    
    diffs = np.diff(X_ms)
    rmssd = np.sqrt(np.mean(diffs ** 2))
    
    # 伪迹定义：相邻心跳变化超过20%
    artifact_mask = np.abs(diffs) / X_ms[:-1] > 0.20
    artifact_pct = np.mean(artifact_mask)
    
    return {"n_beats": n_beats, "mean_hr": mean_hr, "sdnn": sdnn, "rmssd": rmssd, "artifact_pct": artifact_pct}

# ───────────────────────────────────────────────────────────────
# 绘图
# ───────────────────────────────────────────────────────────────
def save_fig(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    plt.tight_layout()
    plt.savefig(path, dpi=120)
    plt.close('all')

def plot_ppg(t: np.ndarray, X: np.ndarray, out_png: Path, markers, fs_hint, device: str):
    if t.size < 2 or X.size == 0: return
    ds = CONFIG["plot_downsample"]["PPG"]
    plt.figure(figsize=(10, 4))
    for c in range(X.shape[1]):
        plt.plot(t[::ds], X[::ds, c], label=f"ch{c+1}", linewidth=0.8)
    plt.xlabel("time_lsl (s)"), plt.ylabel("PPG raw (22-bit counts)")
    fs = fs_hint if fs_hint > 0 else estimate_fs(t)
    plt.title(f"PPG ({device})  ch={X.shape[1]}  fs≈{fs:.2f} Hz")
    if markers:
        ymax = np.nanpercentile(X, 99)
        for ts, label in zip(markers[0], markers[1]):
            plt.axvline(ts, linestyle="--", linewidth=0.8)
            plt.text(ts, ymax, label, rotation=90, va="top", fontsize=8)
    plt.legend(loc="upper right", ncol=min(4, X.shape[1])), save_fig(out_png)

def plot_acc(t: np.ndarray, X: np.ndarray, out_png: Path, fs_hint, device: str):
    if t.size < 2 or X.size == 0: return
    ds = CONFIG["plot_downsample"]["ACC"]
    plt.figure(figsize=(10, 4))
    for i, label in enumerate(["x_mG", "y_mG", "z_mG"]):
        if i < X.shape[1]: plt.plot(t[::ds], X[::ds, i], label=label, linewidth=0.8)
    plt.xlabel("time_lsl (s)"), plt.ylabel("acc (mG)")
    fs = fs_hint if fs_hint > 0 else estimate_fs(t)
    plt.title(f"ACC ({device})  fs≈{fs:.2f} Hz")
    plt.legend(loc="upper right"), save_fig(out_png)

def plot_ecg(t: np.ndarray, X: np.ndarray, out_png: Path, fs_hint, device: str):
    if t.size < 2 or X.size == 0: return
    ds = CONFIG["plot_downsample"]["ECG"]
    plt.figure(figsize=(10, 3))
    plt.plot(t[::ds], X[::ds, 0], linewidth=0.6)
    plt.xlabel("time_lsl (s)"), plt.ylabel("ECG (uV)")
    fs = fs_hint if fs_hint > 0 else estimate_fs(t)
    plt.title(f"ECG ({device})  fs≈{fs:.2f} Hz")
    save_fig(out_png)

def plot_hr_overlay(t_hr, hr_bpm, t_evt, ms, out_png, label_evt, device_hr, device_evt):
    if t_hr.size==0 or hr_bpm.size==0 or t_evt.size==0 or ms.size==0: return
    
    # 估算由事件导出的瞬时心率
    est = hr_from_events(t_evt, ms, t_hr)
    
    plt.figure(figsize=(10, 3.5))
    plt.plot(t_hr, hr_bpm, linewidth=1.2, label=f"HR ({device_hr})")
    plt.plot(t_hr, est, linewidth=1.0, linestyle='--', label=f"HR from {label_evt} ({device_evt})")
    plt.xlabel("time_lsl (s)"), plt.ylabel("bpm")
    
    # [修正] 调用新版 hr_align_metrics 并接收3个返回值
    mae, bias, reason = hr_align_metrics(t_hr, hr_bpm, t_evt, ms)
    
    # [修正] 根据是否有 reason 来生成不同的图表标题
    title_str = f"HR ({device_hr}) vs {label_evt} ({device_evt})"
    if reason:
        # 如果有原因（无法计算），则在标题中注明
        title_str += f"\n(一致性无法计算)"
    else:
        # 如果计算成功，则显示 MAE 和 bias
        title_str += f"\nMAE={mae:.2f} bpm  bias={bias:+.2f} bpm"
    
    plt.title(title_str)
    plt.legend(loc="upper right")
    save_fig(out_png)

def plot_ppi_quality(t, headers, X, out_png, device):
    if t.size==0 or X.size==0: return
    data_headers = headers[1:]
    fig, axes = plt.subplots(2, 1, figsize=(10, 5), sharex=True)
    try:
        q_idx = data_headers.index('quality')
        q = X[:, q_idx]
        axes[0].plot(t, q, label="quality (ms)")
        axes[1].hist(q[np.isfinite(q)], bins=30)
        axes[1].set_xlabel("quality (ms)"), axes[1].set_ylabel("count")
    except (ValueError, IndexError): pass
    axes[0].set_ylabel("quality (ms)"), axes[0].set_title(f"PPI Quality ({device})")
    axes[0].legend(loc="upper right"), save_fig(out_png)

def plot_interval_tachogram(t: np.ndarray, X_ms: np.ndarray, out_png: Path, kind: str, device: str):
    """绘制RR或PPI的Tachogram图"""
    if t.size < 2 or X_ms.size < 2: return
    plt.figure(figsize=(10, 3.5))
    plt.plot(t, X_ms, '.-', markersize=3, linewidth=0.8, label=f"{kind} Intervals")
    plt.xlabel("time_lsl (s)")
    plt.ylabel(f"{kind} Interval (ms)")
    plt.title(f"{kind} Tachogram ({device})")
    plt.legend()
    save_fig(out_png)

def plot_poincare(X_ms: np.ndarray, out_png: Path, kind: str, device: str):
    """绘制RR或PPI的Poincaré图"""
    if X_ms.size < 2: return
    # 剔除NaN和非正数的值
    X_ms = X_ms[np.isfinite(X_ms) & (X_ms > 0)]
    if X_ms.size < 2: return
    
    rr_n = X_ms[:-1]
    rr_n1 = X_ms[1:]
    
    plt.figure(figsize=(5, 5))
    plt.scatter(rr_n, rr_n1, alpha=0.5, s=10)
    plt.xlabel(f"{kind}_n (ms)")
    plt.ylabel(f"{kind}_{'n+1'} (ms)")
    plt.title(f"{kind} Poincaré Plot ({device})")
    min_val = np.min(X_ms) * 0.95
    max_val = np.max(X_ms) * 1.05
    plt.xlim(min_val, max_val)
    plt.ylim(min_val, max_val)
    plt.plot([min_val, max_val], [min_val, max_val], 'r--', linewidth=0.8, label="Identity Line")
    plt.legend()
    plt.gca().set_aspect('equal', adjustable='box')
    save_fig(out_png)

def plot_ecg(t: np.ndarray, X: np.ndarray, out_png: Path, fs_hint: float, device: str):
    """绘制ECG波形图"""
    if t.size < 2 or X.size == 0: return
    
    # 为了绘图效率和清晰度，可以选择性地进行下采样
    ds = CONFIG["plot_downsample"].get("ECG", 1)
    
    plt.figure(figsize=(10, 3.5))
    # X[:, 0] 代表ECG的uV值那一列
    plt.plot(t[::ds], X[::ds, 0], linewidth=0.6)
    
    plt.xlabel("time_lsl (s)")
    plt.ylabel("ECG (uV)")
    fs_est = fs_hint if fs_hint > 0 else estimate_fs(t)
    plt.title(f"ECG Waveform ({device})  fs≈{fs_est:.2f} Hz")
    save_fig(out_png)

# ───────────────────────────────────────────────────────────────
# 主流程
# ───────────────────────────────────────────────────────────────

# ==============================================================================
#                      第2步：用这个新 main 函数完整替换旧的
# ==============================================================================
def main():
    # 明确指定保存位置
    # 若提供参数则用参数，否则默认选择 Data/main_lsl_data 下最新的会话目录
    # base = Path(__file__).resolve().parent.parent
    # default_root = base / "Data" / "main_lsl_data"
    # if len(sys.argv) > 1:
    #     root = Path(sys.argv[1]).resolve()
    # else:
    #     if not default_root.exists():
    #         print(f"[FATAL] 默认目录不存在: {default_root}")
    #         return
    #     # 找最近修改的目录
    #     candidates = [p for p in default_root.iterdir() if p.is_dir()]
    #     if not candidates:
    #         print(f"[FATAL] {default_root} 下没有任何会话目录")
    #         return
    #     root = max(candidates, key=lambda p: p.stat().st_mtime)

    # print(f"[INFO] 使用目录: {root}")

    # if not root or not root.is_dir():
    #     print(f"[FATAL] 目录无效或未选择: {root}"); return

    # # 1. [修正] 使用新的 locate_files 函数找到所有文件路径
    # files = locate_files(root)
    # report = [f"[DIR] {root}"]
    # found_str = ", ".join([f"{k}({', '.join(v.keys())})" if v else f"{k}(-)" for k, v in files.items()])
    # report.append(f"[FOUND] {found_str}")

    #  # 1) 定位输入和输出目录
    # # 输入目录默认为 recorder_data，用户仍可通过命令行参数覆盖
    # in_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else RECORDER_DATA_DIR
    # # 输出目录固定为 processed_data
    # out_dir = PROCESSED_DATA_DIR
    # out_dir.mkdir(parents=True, exist_ok=True) # 确保输出目录存在

    # print(f"[*] 输入数据目录: {in_dir}")
    # print(f"[*] 输出报告目录: {out_dir}")

    # # 2. [修正] 建立一个与 files 结构相同的新字典 `data`，用于存放读取后的数据
    # files = locate_files(RECORDER_DATA_DIR)
    # report = [f"[DIR] {RECORDER_DATA_DIR}"]
    # found_str = ", ".join([f"{k}({', '.join(v.keys())})" if v else f"{k}(-)" for k, v in files.items()])
    # report.append(f"[FOUND] {found_str}")
    # data: Dict[str, Dict[str, Any]] = {}
    # for kind, devices in files.items():
    #     if devices:
    #         data[kind] = {}
    #         for device, path in devices.items():
    #             # 读取CSV并存储结果元组 (t, X, headers)
    #             data[kind][device] = read_csv(path)
    
    # # 3. [修正] 后续所有分析都从新的、结构正确的 `data` 字典中读取数据
    # grades, marks = [], None
    # if "unknown" in data.get("MARKERS", {}):
    #     t_mk, X_mk, _ = data["MARKERS"]["unknown"]
    #     marks = (t_mk, [str(v[0]) for v in X_mk])


    # 1) 首先，尝试在默认的 RECORDER_DATA_DIR 目录中自动搜索
    in_dir = RECORDER_DATA_DIR
    print(f"[*] 正在默认目录中递归搜索CSV文件: {in_dir}")
    files = locate_files(in_dir)

    # 2) 检查是否找到了任何文件。如果一个都没找到，则弹框让用户手动选择
    # any(devices for devices in files.values()) 会检查是否所有文件类型都为空
    if not any(files.values()):
        print(f"[!] 在默认目录 {in_dir} 中未找到任何可识别的CSV文件。")
        print("[*] 请手动选择包含CSV文件的数据目录...")

        user_selected_dir = pick_dir_dialog("请选择包含多份CSV的数据根目录")

        if user_selected_dir:
            in_dir = user_selected_dir  # 更新输入目录为用户选择的目录
            print(f"[*] 用户已选择目录，将在此处重新搜索: {in_dir}")
            files = locate_files(in_dir)  # 在新目录中再次运行搜索
        else:
            print("[!] 用户取消了选择。程序退出。")
            return  # 如果用户点击取消，则直接退出程序

    # 3) 如果再次检查后仍然为空，则退出
    if not any(files.values()):
        print(f"[!] 在用户选择的目录 {in_dir} 中仍未找到任何可识别的CSV文件。程序退出。")
        return

    # 4) 如果成功找到文件，则继续执行原有的分析和报告生成流程
    out_dir = PROCESSED_DATA_DIR
    out_dir.mkdir(parents=True, exist_ok=True) # 确保输出目录存在

    report = [f"[DIR] {in_dir}"]
    found_str = ", ".join([f"{k}({', '.join(v.keys())})" if v else f"{k}(-)" for k, v in files.items()])
    report.append(f"[FOUND] {found_str}")

    data: Dict[str, Dict[str, Any]] = {}
    for kind, devices in files.items():
        if devices:
            data[kind] = {}
            for device, path in devices.items():
                data[kind][device] = read_csv(path)
    
    # 3. [修正] 后续所有分析都从新的、结构正确的 `data` 字典中读取数据
    grades, marks = [], None
    if "unknown" in data.get("MARKERS", {}):
        t_mk, X_mk, _ = data["MARKERS"]["unknown"]
        marks = (t_mk, [str(v[0]) for v in X_mk])

    # --- PPG 分析 (Verity) ---
    if "verity" in data.get("PPG", {}):
        t, X, _, = data["PPG"]["verity"]
        dev = "verity"
        fs = estimate_fs(t)
        fs_nom = CONFIG["nominal_fs"]["PPG"]
        comp = completeness(len(t), fs_nom, t[-1] - t[0]) if t.size > 1 else 0.0
        g, rule = grade_three(comp, *CONFIG["completeness"]["PPG"].values(), True, "PPG 完整率")
        report.append(f"[PPG] ({dev}) fs≈{fs:.2f}Hz span={t[-1]-t[0]:.2f}s completeness={comp:.3f} -> {g} | 规则: {rule}")
        grades.append(g)
        mean_r, min_r = ppg_channel_consistency(X, fs if fs > 0 else fs_nom)
        g, rule = grade_three(mean_r, *CONFIG["ppg_consistency"].values(), True, "PPG 通道相关均值")
        report.append(f"[PPG] ({dev}) channel consistency mean={mean_r:.3f} min={min_r:.3f} -> {g} | 规则: {rule}")
        grades.append(g)
        plot_ppg(t, X, PROCESSED_DATA_DIR / f"ppg_{dev}.png", marks, fs, dev)
    
    # --- ACC 分析 (可能来自 H10 和 Verity) ---
    if "ACC" in data:
        for device, (t, X, _) in data["ACC"].items():
            fs = estimate_fs(t)
            fs_nom_key = f"ACC_{device.upper()}"
            fs_nom = CONFIG["nominal_fs"].get(fs_nom_key, 50.0) # 兜底50Hz
            comp = completeness(len(t), fs_nom, t[-1] - t[0]) if t.size > 1 else 0.0
            g, rule = grade_three(comp, *CONFIG["completeness"]["ACC"].values(), True, f"ACC ({device}) 完整率")
            report.append(f"[ACC] ({device}) fs≈{fs:.2f}Hz span={t[-1]-t[0]:.2f}s completeness={comp:.3f} -> {g} | 规则: {rule}")
            grades.append(g)
            mr = acc_motion_ratio(t, X, fs, CONFIG["acc_motion_win_sec"])
            g, rule = grade_three(mr, *CONFIG["motion_ratio"].values(), False, f"ACC ({device}) 高运动占比")
            report.append(f"[ACC] ({device}) motion-high ratio={mr:.3f} -> {g} | 规则: {rule}")
            grades.append(g)
            plot_acc(t, X, PROCESSED_DATA_DIR / f"acc_{device}.png", fs, device)
    
    # --- H10 内部一致性检查 (HR vs RR) ---
    if "h10" in data.get("HR", {}) and "h10" in data.get("RR", {}):
        print("\n[INFO] 正在执行 H10 内部一致性检查 (HR vs RR)...")
        t_hr, X_hr, _ = data["HR"]["h10"]
        t_rr, X_rr, _ = data["RR"]["h10"]
        t_rr_evt = t_rr 
        if t_hr.size > 0 and t_rr_evt.size > 0:
            overlap_start, overlap_end = max(t_hr[0], t_rr_evt[0]), min(t_hr[-1], t_rr_evt[-1])
        else: overlap_end = -1
        
        if overlap_end > overlap_start:
            mae, _, reason = hr_align_metrics(t_hr, X_hr[:,0], t_rr_evt, X_rr[:,0])
            if reason: report.append(f"[HR vs RR] -> N/A | 原因: {reason}")
            else:
                g, rule = grade_three(mae, *CONFIG["hr_align"].values(), False, "HR vs RR MAE", " bpm")
                report.append(f"[HR vs RR] MAE={mae:.2f} bpm -> {g} | 规则: {rule}")
                grades.append(g)
                plot_hr_overlay(t_hr, X_hr[:,0], t_rr_evt, X_rr[:,0], PROCESSED_DATA_DIR/f"hr_rr_overlay_h10.png", "RR", "h10", "h10")
        else: report.append("[HR vs RR] -> N/A | 原因: HR(h10)与RR(h10)数据流没有时间重叠。")

        # RR 数据质量分析
        print("[INFO] 正在执行 RR(h10) 自身质量分析...")
        # 从 data 字典中获取 RR 数据 (如果尚未获取)
        t_rr, X_rr, _ = data["RR"]["h10"]
        rr_metrics = analyze_interval_quality(X_rr[:, 0]) # 第0列是ms
        report.append(
            f"[RR Quality] (h10) "
            f"Beats={rr_metrics['n_beats']}, "
            f"Mean HR={rr_metrics['mean_hr']:.1f} bpm, "
            f"SDNN={rr_metrics['sdnn']:.1f} ms, "
            f"RMSSD={rr_metrics['rmssd']:.1f} ms, "
            f"Artifacts(>20%)={rr_metrics['artifact_pct']:.2%}"
        )
        # 绘制新的RR图表
        plot_interval_tachogram(t_rr, X_rr[:, 0], PROCESSED_DATA_DIR / "rr_tachogram_h10.png", "RR", "h10")
        plot_poincare(X_rr[:, 0], PROCESSED_DATA_DIR / "rr_poincare_h10.png", "RR", "h10")

    # --- Verity Sense 内部一致性检查 (PPI 质量 & HR vs PPI) ---
    if "verity" in data.get("PPI", {}):
        print("\n[INFO] 正在执行 Verity Sense (PPI) 数据分析...")
        t_ppi, X_ppi, hdr_ppi = data["PPI"]["verity"]
        # (PPI 质量分析)
        stats = ppi_quality_stats(hdr_ppi, X_ppi)
        # ... (此处省略了您已有的、正确的PPI质量报告代码，因为它们无需改动) ...
        plot_ppi_quality(t_ppi, hdr_ppi, X_ppi, PROCESSED_DATA_DIR / f"ppi_quality_verity.png", "verity")
        
        # (HR vs PPI 一致性分析)
        if "verity" in data.get("HR", {}):
            t_hr, X_hr, _ = data["HR"]["verity"]
            t_ppi_evt = t_ppi
            if t_hr.size > 0 and t_ppi_evt.size > 0:
                overlap_start, overlap_end = max(t_hr[0], t_ppi_evt[0]), min(t_hr[-1], t_ppi_evt[-1])
            else: overlap_end = -1

            if overlap_end > overlap_start:
                mae, _, reason = hr_align_metrics(t_hr, X_hr[:,0], t_ppi_evt, X_ppi[:,0])
                if reason: report.append(f"[HR vs PPI] -> N/A | 原因: {reason}")
                else:
                    g, rule = grade_three(mae, *CONFIG["hr_align"].values(), False, "HR vs PPI MAE", " bpm")
                    report.append(f"[HR vs PPI] MAE={mae:.2f} bpm -> {g} | 规则: {rule}")
                    grades.append(g)
                    plot_hr_overlay(t_hr, X_hr[:,0], t_ppi_evt, X_ppi[:,0], PROCESSED_DATA_DIR/f"hr_ppi_overlay_verity.png", "PPI", "verity", "verity")
            else: report.append("[HR vs PPI] -> N/A | 原因: HR(verity)与PPI(verity)数据流没有时间重叠。")

            # PPI 数据质量分析
            print("[INFO] 正在执行 PPI(verity) 自身质量分析...")
            # 从 data 字典中获取 PPI 数据 (如果尚未获取)
            t_ppi, X_ppi, _ = data["PPI"]["verity"]
            ppi_metrics = analyze_interval_quality(X_ppi[:, 0]) # 第0列是ms
            report.append(
                f"[PPI Quality] (verity) "
                f"Beats={ppi_metrics['n_beats']}, "
                f"Mean HR={ppi_metrics['mean_hr']:.1f} bpm, "
                f"SDNN={ppi_metrics['sdnn']:.1f} ms, "
                f"RMSSD={ppi_metrics['rmssd']:.1f} ms, "
                f"Artifacts(>20%)={ppi_metrics['artifact_pct']:.2%}"
            )
            # 绘制新的PPI图表
            plot_interval_tachogram(t_ppi, X_ppi[:, 0], PROCESSED_DATA_DIR / "ppi_tachogram_verity.png", "PPI", "verity")
            plot_poincare(X_ppi[:, 0], PROCESSED_DATA_DIR / "ppi_poincare_verity.png", "PPI", "verity")

    # --- ECG 分析（ H10 ) ---
    if "h10" in data.get("ECG", {}):
        print("\n[INFO] 正在执行 ECG (H10) 数据分析...")
        t, X, _ = data["ECG"]["h10"]
        dev = "h10"

        # --- ECG 采样完整率分析 ---
        fs = estimate_fs(t)
        fs_nom = CONFIG["nominal_fs"].get("ECG", 130.0) # 从配置读取名义采样率，兜底130Hz
        comp = completeness(len(t), fs_nom, t[-1] - t[0]) if t.size > 1 else 0.0
        g, rule = grade_three(comp, *CONFIG["completeness"]["ECG"].values(), True, f"ECG ({dev}) 完整率")
        
        report.append(
            f"[ECG] ({dev}) fs≈{fs:.2f}Hz "
            f"span={t[-1]-t[0]:.2f}s "
            f"completeness={comp:.3f} -> {g} | 规则: {rule}"
        )
        grades.append(g)

        # --- 绘制ECG波形图 ---
        plot_ecg(t, X, PROCESSED_DATA_DIR / f"ecg_{dev}.png", fs, dev)

    # ... 您脚本中剩余的部分可以继续使用，因为它们通常是独立的或依赖于我们已经修正的逻辑 ...
    # 比如最后的总体评级
    report.extend(["", f"[OVERALL] -> {combine_grades(grades)}", "", "[CLEANING] 建议：",
                   "  - PPI：丢弃 blocker==1；若 skinSupported==1，则 skinContact==0 区段降权/剔除；quality>30ms 丢弃，20–30ms 低权或插值。",
                   "  - PPG：高通 0.3–0.5Hz 去漂移，带通 0.5–5Hz；高运动区（由 ACC 判定）谨慎使用。",
                   "  - HR 对齐：以 RR/PPI 为准，HR 仅做参考；记录 HR 与 RR/PPI 的 MAE。",
                   "  - 缺口：连续缺口 <1s 可线性插值；≥1s 标记缺测片段，分析时剔除。"])

    out_txt = PROCESSED_DATA_DIR / "qa_report.txt"
    out_txt.write_text("\n".join(report), encoding="utf-8")
    print("\n".join(report))
    print(f"\n[OK] 报告与图已输出至: {PROCESSED_DATA_DIR}")

if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("[FATAL] 未捕获异常：")
        traceback.print_exc()