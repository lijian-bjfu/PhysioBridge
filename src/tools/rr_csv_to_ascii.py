#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xdf_to_ascii.py
----------------
Convert a CSV file (columns: time_lsl, ms, ts) into ASCII heart-beat timestamps for gHRV.
All conversions are derived from the CSV; no XDF reading or guessing is performed.

If neither R-peaks nor RR/IBI are present, ECG-based peak detection is NOT
performed in this utility to avoid heavyweight dependencies. In that case,
the script will report what streams are available and exit.

Output (all under: RECORDER_DATA_DIR / <CSV-stem> / ascii_files):
  - beats_ms.txt              One value per line, integer milliseconds from t0
  - rr_ms.txt (optional)      RR durations in milliseconds if an RR/IBI stream exists
  - beats_s.txt               One value per line, seconds from t0 (float)
  - rr_s.txt (optional)       RR durations in seconds if an RR/IBI stream exists

Input expectation (this simplified build):
  - One RR/IBI stream with exactly three channel labels: time_lsl, ms, ts (case-insensitive).
    The conversion ALWAYS reads the second column (ms) as RR in milliseconds; no guessing.

Usage:
  - Double click or run without arguments to pick a file via GUI dialog.
  - Or run from terminal: python xdf_to_ascii.py /path/to/file.csv

RECORDER_DATA_DIR resolution order:
  1) Environment variable RECORDER_DATA_DIR
  2) Default to ~/RecorderData

Author: (your lab / project name)
"""
from __future__ import annotations

import argparse
import os
import sys
import textwrap
from pathlib import Path
from typing import Optional, Tuple, List
import csv

# 获取当前工作目录
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)
from paths import RECORDER_DATA_DIR

# Optional GUI picker (Tkinter). Falls back to None if not available.
try:
    from tkinter import Tk, filedialog  # type: ignore
except Exception:  # pragma: no cover
    Tk = None  # type: ignore
    filedialog = None  # type: ignore

try:
    import numpy as np  # type: ignore
except ImportError:
    print("错误：未找到依赖 numpy。请先安装：pip install numpy", file=sys.stderr)
    sys.exit(2)


# --------------------------- GUI picker ---------------------------

def pick_file_dialog() -> Optional[Path]:
    """
    Show a file-open dialog to choose a CSV file.
    Returns None if Tkinter is unavailable or user cancels.
    """
    if Tk is None or filedialog is None:
        return None
    root = Tk()
    root.withdraw()
    root.update()
    p = filedialog.askopenfilename(
        title="选择 RR CSV 文件",
        initialdir=str(RECORDER_DATA_DIR),
        filetypes=[("CSV files", "*.csv"), ("All files", "*.*")],
    )
    root.destroy()
    return Path(p) if p else None


# --------------------------- CSV helpers ---------------------------

def read_rr_ms_from_csv(csv_path: Path) -> np.ndarray:
    """Read a CSV with exactly three columns [time_lsl, ms, ts] (case-insensitive)
    and return RR in milliseconds as a 1-D float numpy array.
    """
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            raise ValueError("CSV 为空")
        cols = [h.strip().lower() for h in header]
        if cols != ["time_lsl", "ms", "te"]:
            raise ValueError(f"CSV 列名必须严格为 [time_lsl, ms, te]，实际为: {cols}")
        rr_ms_list = []
        for row in reader:
            if not row or len(row) < 2:
                continue
            val = row[1].strip()
            if val == "":
                continue
            rr_ms_list.append(float(val))
    rr_ms = np.asarray(rr_ms_list, dtype=float)
    if rr_ms.size < 2:
        raise ValueError("RR 数据量不足（少于 2 个样本）")
    if not np.all(np.isfinite(rr_ms)):
        raise ValueError("RR 数据包含非数值/无穷值")
    if np.nanmedian(rr_ms) <= 0:
        raise ValueError("RR 中位数非正，数据异常")
    return rr_ms


# --------------------------- Conversion logic ---------------------------


def beats_from_rr_ms(rr_ms: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """Convert RR in milliseconds to beat timestamps in milliseconds (relative to t0).
    Returns (beats_ms, rr_ms_rounded).
    """
    beats_ms = np.cumsum(rr_ms)
    beats_ms -= beats_ms[0]
    return np.round(beats_ms).astype(np.int64), np.round(rr_ms).astype(np.int64)


# --------------------------- IO helpers ---------------------------

def ensure_out_dir(csv_path: Path) -> Path:
    out_root = RECORDER_DATA_DIR
    out_dir = out_root / csv_path.stem / "ascii_files"
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir


def write_ascii(filepath: Path, array_ms: np.ndarray) -> None:
    # gHRV expects plain ASCII, one integer per line (milliseconds)
    with filepath.open("w", encoding="utf-8", newline="\n") as f:
        for v in array_ms:
            f.write(f"{int(v)}\n")


def write_ascii_float(filepath: Path, array: np.ndarray, decimals: int = 6) -> None:
    """Write a plain-text ASCII file, one float per line, with given decimals."""
    fmt = f"{{:.{decimals}f}}\n"
    with filepath.open("w", encoding="utf-8", newline="\n") as f:
        for v in array:
            f.write(fmt.format(float(v)))


# --------------------------- Main ---------------------------

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="xdf_to_ascii.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=textwrap.dedent(__doc__ or ""),
    )
    parser.add_argument("csv", nargs="?", help="待转换的 RR CSV 文件路径")
    args = parser.parse_args(argv)

    # Resolve input path
    if args.csv:
        csv_path = Path(args.csv).expanduser().resolve()
    else:
        csv_path = pick_file_dialog()

    if not csv_path:
        print("已取消：未选择 RR CSV 文件。", file=sys.stderr)
        return 1
    if not csv_path.exists():
        print(f"错误：文件不存在：{csv_path}", file=sys.stderr)
        return 2
    if csv_path.suffix.lower() != ".csv":
        print(f"警告：选择的文件扩展名不是 .csv：{csv_path.suffix}", file=sys.stderr)

    print(f"[1/3] 读取 CSV：{csv_path}")

    try:
        rr_ms = read_rr_ms_from_csv(csv_path)
    except Exception as e:
        print(f"错误：RR 提取失败：{e}", file=sys.stderr)
        return 5

    out_dir = ensure_out_dir(csv_path)

    print(f"[2/3] 解析 RR(ms) → 生成 beats 与多格式导出")

    # 转换：RR(ms) → beats(ms)
    beats_ms, rr_ms_rounded = beats_from_rr_ms(rr_ms)

    # 输出（毫秒与秒两套）
    out_beats_ms = out_dir / "beats_ms.txt"
    out_rr_ms = out_dir / "rr_ms.txt"
    write_ascii(out_beats_ms, beats_ms)
    write_ascii(out_rr_ms, rr_ms_rounded)

    beats_s = beats_ms.astype(float) / 1000.0
    rr_s = rr_ms.astype(float) / 1000.0
    out_beats_s = out_dir / "beats_s.txt"
    out_rr_s = out_dir / "rr_s.txt"
    write_ascii_float(out_beats_s, beats_s)
    write_ascii_float(out_rr_s, rr_s)

    print(f"[3/3] 输出目录：{out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
