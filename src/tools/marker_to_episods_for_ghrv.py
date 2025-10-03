#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
marker_to_episodes.py
---------------------
用于将markers.csv转换为gHRV可读的episodes.txt

Convert an LSL marker CSV (columns: time_lsl,label) into a gHRV-compatible
episodes text file with three columns (whitespace-separated):

    Init_Time   Tag   Durat

Key properties:
- Input times are **LSL seconds** (float). Output times are **seconds relative
  to the HR data start** (t0), i.e., Init_Time >= 0.
- t0 resolution:
    1) Preferred: read an RR CSV (time_lsl,ms,ts) and set t0 = first RR's time_lsl.
    2) Fallback: if user cancels RR selection, set t0 = first marker's time_lsl.
- Episode construction rule (label-agnostic):
    We do NOT interpret specific label names. Episodes are built strictly by order:
    for each consecutive pair of markers (i, i+1), create one episode with:
        Init_Time = time_lsl[i] - t0
        Tag       = label[i]   (preserve original label)
        Durat     = (time_lsl[i+1] - time_lsl[i])
    Only positive-duration episodes are kept. The final lone marker (without a following marker)
    does not form an episode because no end boundary is available.

Output location:
  RECORDER_DATA_DIR / <marker_csv_stem> / ascii_files / episodes.txt

Usage:
  - Double click or run without args and choose files via GUI dialogs.
  - Or run: python marker_to_episodes.py /path/to/markers.csv [/path/to/rr.csv]

Author: (your lab / project name)
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from dataclasses import dataclass
from typing import List, Optional, Tuple
from pathlib import Path

# 获取当前工作目录
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)
from paths import RECORDER_DATA_DIR

try:
    from tkinter import Tk, filedialog  # type: ignore
except Exception:  # pragma: no cover
    Tk = None  # type: ignore
    filedialog = None  # type: ignore



# --------------------------- GUI pickers ---------------------------

def pick_markers_csv() -> Optional[Path]:
    if Tk is None or filedialog is None:
        return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askopenfilename(
        title="选择 Marker CSV 文件（time_lsl,label）",
        initialdir=str(RECORDER_DATA_DIR),
        filetypes=[("CSV files","*.csv"),("All files","*.*")]
    )
    root.destroy()
    return Path(p) if p else None


def pick_rr_csv_optional() -> Optional[Path]:
    if Tk is None or filedialog is None:
        return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askopenfilename(
        title="（可选）选择 RR CSV（time_lsl,ms,ts）以对齐 t0；取消则以第一条 marker 为 t0",
        initialdir=str(RECORDER_DATA_DIR),
        filetypes=[("CSV files","*.csv"),("All files","*.*")]
    )
    root.destroy()
    return Path(p) if p else None


# --------------------------- Data types ---------------------------

@dataclass
class Marker:
    t: float
    label: str


# --------------------------- IO helpers ---------------------------

def read_markers(csv_path: Path) -> List[Marker]:
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            raise ValueError("Marker CSV 为空")
        cols = [h.strip().lower() for h in header]
        if cols != ["time_lsl","label"]:
            raise ValueError(f"Marker CSV 列名必须严格为 [time_lsl,label]，实际为: {cols}")
        out: List[Marker] = []
        for row in reader:
            if not row or len(row) < 2:
                continue
            t_str, lab = row[0].strip(), row[1].strip()
            if not t_str or not lab:
                continue
            out.append(Marker(float(t_str), lab))
    if not out:
        raise ValueError("Marker CSV 没有有效数据行")
    # sort by time just in case
    out.sort(key=lambda m: m.t)
    return out


def read_rr_t0_from_csv(csv_path: Path) -> float:
    """Return the first RR's time_lsl as t0 (seconds)."""
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            raise ValueError("RR CSV 为空")
        cols = [h.strip().lower() for h in header]
        if cols not in (["time_lsl","ms","te"]):
            raise ValueError(f"RR CSV 列名必须为 [time_lsl,ms,te]，实际为: {cols}")
        for row in reader:
            if not row or len(row) < 1:
                continue
            t_str = row[0].strip()
            if t_str:
                return float(t_str)
    raise ValueError("RR CSV 未找到第一条 time_lsl")


# --------------------------- Conversion ---------------------------

@dataclass
class Episode:
    init_time: float
    tag: str
    durat: float


def build_episodes(markers: List[Marker], t0: float) -> List[Episode]:
    """
    Build episodes in a label-agnostic, order-only manner.
    Rule: for each consecutive pair of markers (i, i+1), build one episode:
      Init_Time = markers[i].time - t0  (seconds, >= 0)
      Tag       = markers[i].label      (preserve original)
      Durat     = markers[i+1].time - markers[i].time
    Only positive-duration episodes are kept. Lone trailing marker is ignored.
    """
    # Normalize to relative seconds and drop markers before t0
    m_rel = [Marker(t=m.t - t0, label=m.label) for m in markers if (m.t - t0) >= 0.0]
    # Ensure sorted by time
    m_rel.sort(key=lambda x: x.t)

    if len(m_rel) < 2:
        present = ", ".join(f"{mi.label}@{mi.t:.3f}s" for mi in m_rel) or "<none>"
        raise ValueError(
            "至少需要两个不同时刻的标记才能构建 episodes。\n"
            f"t0={t0:.6f}，可用标记（相对秒）: [{present}]。"
        )

    episodes: List[Episode] = []
    for i in range(len(m_rel) - 1):
        t_start = m_rel[i].t
        t_end = m_rel[i + 1].t
        if t_end <= t_start:
            # Skip non-positive or non-increasing time; continue to next pair
            continue
        episodes.append(Episode(t_start, m_rel[i].label, t_end - t_start))

    # Keep only positive durations and sort by start time
    episodes = [e for e in episodes if e.durat > 0]
    episodes.sort(key=lambda e: e.init_time)

    if not episodes:
        present = ", ".join(f"{mi.label}@{mi.t:.3f}s" for mi in m_rel)
        raise ValueError(
            "未能构建任何有效 episodes（所有相邻标记对的时差均非正）。\n"
            f"可用标记（相对秒）: [{present}]。"
        )
    return episodes


# --------------------------- Write ---------------------------

def ensure_out_dir(src_path: Path) -> Path:
    out_dir = RECORDER_DATA_DIR / src_path.stem / "ascii_files"
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir


def write_episodes_txt(path: Path, episodes: List[Episode]) -> None:
    def _sec_to_hms(t: float) -> str:
        # Convert seconds to HH:MM:SS.sss for gHRV/RHRV
        if t < 0:
            t = 0.0
        h = int(t // 3600)
        m = int((t - h*3600) // 60)
        s = t - h*3600 - m*60
        return f"{h:02d}:{m:02d}:{s:06.3f}"

    with path.open("w", encoding="utf-8", newline="\n") as f:
        # Header required by many gHRV/RHRV examples
        f.write("Init_Time\tResp_Events\tDurat\n")
        for e in episodes:
            f.write(f"{_sec_to_hms(e.init_time)}\t{e.tag}\t{e.durat:.6f}\n")


# --------------------------- Main ---------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Convert LSL markers to gHRV episodes")
    ap.add_argument("markers", nargs="?", help="Marker CSV path (time_lsl,label)")
    ap.add_argument("rr", nargs="?", help="Optional RR CSV path (time_lsl,ms,te) for t0 alignment")
    args = ap.parse_args(argv)

    # pick files via GUI if not provided
    if args.markers:
        markers_path = Path(args.markers).expanduser().resolve()
    else:
        markers_path = pick_markers_csv()

    if not markers_path:
        print("已取消：未选择 Marker CSV。", file=sys.stderr); return 1
    if not markers_path.exists():
        print(f"错误：文件不存在：{markers_path}", file=sys.stderr)
        return 2

    # optional RR CSV for t0
    if args.rr:
        rr_path = Path(args.rr).expanduser().resolve()
    else:
        rr_path = pick_rr_csv_optional()

    print(f"[1/4] 读取 Marker CSV：{markers_path}")
    try:
        markers = read_markers(markers_path)
    except Exception as e:
        print(f"错误：读取 markers 失败：{e}", file=sys.stderr); return 3

    # resolve t0
    if rr_path and rr_path.exists():
        try:
            t0 = read_rr_t0_from_csv(rr_path)
            print(f"[2/4] 对齐 t0 = 第一条 RR 的 time_lsl = {t0:.6f} s")
        except Exception as e:
            print(f"警告：读取 RR CSV 失败（将退回以第一条 marker 为 t0）：{e}", file=sys.stderr)
            t0 = markers[0].t
            print(f"[2/4] t0 = 第一条 marker 的 time_lsl = {t0:.6f} s")
    else:
        t0 = markers[0].t
        print(f"[2/4] 未提供 RR CSV；t0 = 第一条 marker 的 time_lsl = {t0:.6f} s")

    # build episodes
    try:
        episodes = build_episodes(markers, t0)
    except Exception as e:
        print(f"错误：构建 episodes 失败：{e}", file=sys.stderr); return 4

    # write
    out_dir = ensure_out_dir(markers_path)
    out_txt = out_dir / "episodes.txt"
    write_episodes_txt(out_txt, episodes)
    print(f"[3/4] 已导出 episodes：{out_txt} （{len(episodes)} 段）")

    # echo summary
    for e in episodes:
        print(f"    {e.init_time:.3f}  {e.tag:12s}  {e.durat:.3f}")

    print(f"[4/4] 输出目录：{out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
