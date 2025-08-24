#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
XDF → CSV 转换器（适配 PB_UDP_TEST / PB_MARKERS_TEST）
- 在 IDE 直接运行：若无命令行参数，自动弹出文件选择器挑选 .xdf，并可选择输出目录
- 从数据流（JSON 文本）拆分到四个 CSV：HR / RR / ECG / ACC
- 从标记流导出 markers CSV
- 导出后打印：每类数据的行数与时间跨度、采样率/量程集合（若适用）、CSV 路径
- 打印每个 CSV 的前若干行（默认 3 行），作为“表单结果”示例
- 打印数据字典说明（字段含义与单位）

依赖：
  pip install pyxdf
"""

from __future__ import annotations
import argparse
import csv
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# —— 配置：每个 CSV 打印前几行示例 ——
CSV_HEAD_ROWS = 3

# —— 与 qa_check.py 一致的“对话框优先”交互方式 ——
try:
    from tkinter import Tk, filedialog
except Exception:
    Tk = None
    filedialog = None

def pick_file_dialog() -> Optional[Path]:
    if Tk is None or filedialog is None:
        return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askopenfilename(
        title="选择 XDF 文件",
        filetypes=[("XDF files", "*.xdf"), ("All files", "*.*")]
    )
    root.destroy()
    return Path(p) if p else None

def pick_dir_dialog(title: str = "选择输出目录") -> Optional[Path]:
    if Tk is None or filedialog is None:
        return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askdirectory(title=title, mustexist=True)
    root.destroy()
    return Path(p) if p else None

# —— 基础工具 ——
def ensure_out(path: Path):
    path.mkdir(parents=True, exist_ok=True)

def find_stream(streams: List[Dict[str, Any]], name: str) -> Optional[Dict[str, Any]]:
    for st in streams:
        if st.get("info", {}).get("name", [None])[0] == name:
            return st
    return None

def open_writer(path: Path, header: List[str]) -> Tuple[csv.writer, Any]:
    f = path.open("w", newline="", encoding="utf-8")
    w = csv.writer(f)
    w.writerow(header)
    return w, f

def print_csv_head(path: Path, n: int = CSV_HEAD_ROWS):
    try:
        with path.open("r", encoding="utf-8") as f:
            lines = f.readlines()
        print(f"[HEAD] {path.name}")
        if len(lines) <= 1:
            print("  (empty)")
            return
        # 打印表头 + 前 n 行
        print("  " + lines[0].rstrip("\n"))
        for line in lines[1:1+n]:
            print("  " + line.rstrip("\n"))
    except Exception as e:
        print(f"[WARN] 读取 {path.name} 失败：{e}")

# —— 参数 ——
def parse_args():
    ap = argparse.ArgumentParser(description="Convert PB XDF to per-signal CSVs.")
    ap.add_argument("xdf", nargs="?", type=Path, help="XDF 文件路径（可省略，IDE 下将弹对话框）")
    ap.add_argument("--out", type=Path, default=None, help="输出目录（默认：<xdf_dir>/csv_<xdf_stem>）")
    ap.add_argument("--data-name", default="PB_UDP_TEST", help="数据流名称（默认 PB_UDP_TEST）")
    ap.add_argument("--marker-name", default="PB_MARKERS_TEST", help="标记流名称（默认 PB_MARKERS_TEST）")
    ap.add_argument("--time-base", choices=["lsl","device"], default="lsl",
                    help="时间列：'lsl'（推荐）或 'device'（t_device）")
    return ap.parse_args()

def main():
    args = parse_args()

    # 1) 获取 XDF 文件
    xdf_path: Optional[Path] = args.xdf
    if xdf_path is None:
        xdf_path = pick_file_dialog()
        if xdf_path is None:
            try:
                raw = input("请输入 XDF 文件路径：").strip().strip('"').strip("'")
                xdf_path = Path(raw) if raw else None
            except EOFError:
                xdf_path = None
    if xdf_path is None or not xdf_path.exists():
        print("[ERROR] 未提供有效的 .xdf 文件路径。")
        return

    # 2) 选择输出目录（可选）
    out_dir: Optional[Path] = args.out
    if out_dir is None:
        out_dir = pick_dir_dialog("选择输出目录（取消则用默认）")
        if out_dir is None:
            out_dir = xdf_path.parent / f"csv_{xdf_path.stem}"
    ensure_out(out_dir)

    # 3) 读取 XDF
    try:
        import pyxdf
    except ImportError:
        print("缺少依赖：pyxdf。请先执行：pip install pyxdf")
        return

    print(f"[LOAD] {xdf_path}")
    try:
        streams, _ = pyxdf.load_xdf(str(xdf_path))
    except Exception as e:
        print(f"[ERROR] 无法读取 XDF：{e}")
        return

    if not streams:
        print("[ERROR] 文件中没有任何流")
        return

    # 4) 查找数据流与标记流
    st_data = find_stream(streams, args.data_name)
    st_mark = find_stream(streams, args.marker_name)
    if not st_data:
        print(f"[ERROR] 未找到数据流：{args.data_name}")
        return
    if not st_mark:
        print(f"[WARN] 未找到标记流：{args.marker_name}（将仅导出数据 CSV）")

    # 5) 创建 CSV 写入器
    stem = xdf_path.stem
    p_hr  = out_dir / f"{stem}_hr.csv"
    p_rr  = out_dir / f"{stem}_rr.csv"
    p_ecg = out_dir / f"{stem}_ecg.csv"
    p_acc = out_dir / f"{stem}_acc.csv"
    p_mk  = out_dir / f"{stem}_markers.csv"

    w_hr,  f_hr  = open_writer(p_hr,  ["time_lsl", "t_device", "bpm", "device"])
    w_rr,  f_rr  = open_writer(p_rr,  ["time_lsl", "t_device", "ms", "device", "seq"])
    w_ecg, f_ecg = open_writer(p_ecg, ["time_lsl", "t_device", "uV", "device", "seq", "fs"])
    w_acc, f_acc = open_writer(p_acc, ["time_lsl", "t_device", "x_mG", "y_mG", "z_mG", "device", "seq", "fs", "range_g"])

    # 6) 解析数据流（JSON）
    series = st_data["time_series"]   # (N, 1) JSON 字符串
    stamps = st_data["time_stamps"]   # (N,)
    n = len(stamps)

    # 摘要累积器
    row_counts  = Counter()                    # 各类型行数（展开后）
    batch_counts= Counter()                    # 各类型批数（原始 JSON 条数）
    first_ts    = defaultdict(lambda: None)    # 各类型第一条 time_lsl
    last_ts     = defaultdict(lambda: None)    # 各类型最后一条 time_lsl
    fs_seen     = defaultdict(set)             # 采样率集合（ecg/acc）
    range_seen  = set()                        # acc 量程集合

    def upd_span(t: float, typ: str):
        if first_ts[typ] is None:
            first_ts[typ] = t
        last_ts[typ] = t

    def time_col(lsl_ts: float, obj: Dict[str, Any]) -> float:
        if args.time_base == "lsl":
            return float(lsl_ts)
        return float(obj.get("t_device") or lsl_ts)

    for i in range(n):
        raw = series[i][0]
        lsl_ts = stamps[i]
        try:
            obj = json.loads(raw)
        except Exception as e:
            print(f"[WARN] JSON 解析失败 idx={i}: {e}")
            continue

        typ = obj.get("type", "")
        batch_counts[typ] += 1

        if typ == "hr":
            t = time_col(lsl_ts, obj)
            w_hr.writerow([t, obj.get("t_device",""), obj.get("bpm",""), obj.get("device","")])
            row_counts["hr"] += 1
            upd_span(t, "hr")

        elif typ == "rr":
            t = time_col(lsl_ts, obj)
            w_rr.writerow([t, obj.get("t_device",""), obj.get("ms",""),
                           obj.get("device",""), obj.get("seq","")])
            row_counts["rr"] += 1
            upd_span(t, "rr")

        elif typ == "ecg":
            fs = float(obj.get("fs", 130))
            uV = obj.get("uV", [])
            seq = obj.get("seq", "")
            dev = obj.get("device", "")
            tdev= obj.get("t_device", "")
            fs_seen["ecg"].add(fs)
            nbat = len(uV)
            if nbat > 0 and fs > 0:
                dt = 1.0 / fs
                t0 = float(lsl_ts) - (nbat - 1) * dt  # 右对齐展开
                for k, val in enumerate(uV):
                    t = t0 + k * dt
                    w_ecg.writerow([t, tdev, val, dev, seq, fs])
                row_counts["ecg"] += nbat
                upd_span(t0, "ecg")
                upd_span(t0 + (nbat - 1) * dt, "ecg")

        elif typ == "acc":
            fs = float(obj.get("fs", 50))
            mG = obj.get("mG", [])
            rng = obj.get("range_g", "")
            seq = obj.get("seq", "")
            dev = obj.get("device", "")
            tdev= obj.get("t_device", "")
            fs_seen["acc"].add(fs)
            if rng != "":
                try:
                    range_seen.add(int(rng))
                except Exception:
                    pass
            nbat = len(mG)
            if nbat > 0 and fs > 0:
                dt = 1.0 / fs
                t0 = float(lsl_ts) - (nbat - 1) * dt
                for k, trip in enumerate(mG):
                    try:
                        x, y, z = trip
                    except Exception:
                        continue
                    t = t0 + k * dt
                    w_acc.writerow([t, tdev, x, y, z, dev, seq, fs, rng])
                row_counts["acc"] += nbat
                upd_span(t0, "acc")
                upd_span(t0 + (nbat - 1) * dt, "acc")

        # 其它类型（marker/meta/heartbeat）不写入数据 CSV

    f_hr.close(); f_rr.close(); f_ecg.close(); f_acc.close()

    # 7) 导出标记流（若存在）
    mark_rows = 0
    if st_mark:
        w_mk, f_mk = open_writer(p_mk, ["time_lsl", "label", "note", "packet_id"])
        m_series = st_mark["time_series"]; m_stamps = st_mark["time_stamps"]
        m_n = len(m_stamps)
        for i in range(m_n):
            row = m_series[i]
            try:
                obj = json.loads(row[0])
                label = obj.get("label",""); note = obj.get("note",""); pid = obj.get("packet_id","")
            except Exception:
                label = str(row[0]); note = ""; pid = ""
            w_mk.writerow([m_stamps[i], label, note, pid])
            mark_rows += 1
        f_mk.close()

    # 8) 摘要打印
    def span_str(typ: str) -> str:
        a, b = first_ts.get(typ), last_ts.get(typ)
        if a is None or b is None:
            return "0.00s"
        return f"{(b - a):.2f}s"

    print("\n[SUMMARY]")
    for typ in ("ecg","acc","hr","rr"):
        if row_counts[typ] > 0:
            extra = ""
            if typ == "ecg" and fs_seen["ecg"]:
                extra = f" | fs={sorted(fs_seen['ecg'])}"
            if typ == "acc" and fs_seen["acc"]:
                extra = f" | fs={sorted(fs_seen['acc'])} | range_g={sorted(range_seen)}"
            print(f"  - {typ.upper():<3}: rows={row_counts[typ]} | batches={batch_counts[typ]} | span={span_str(typ)}{extra}")
        else:
            print(f"  - {typ.upper():<3}: rows=0")

    if st_mark:
        print(f"  - MARKERS: rows={mark_rows}")

    print("\n[FILES]")
    print(f"  HR : {p_hr}")
    print(f"  RR : {p_rr}")
    print(f"  ECG: {p_ecg}")
    print(f"  ACC: {p_acc}")
    if st_mark:
        print(f"  MRK: {p_mk}")

    # 9) 打印各 CSV 表单前几行
    print("\n[SAMPLE HEAD]")
    print_csv_head(p_hr)
    print_csv_head(p_rr)
    print_csv_head(p_ecg)
    print_csv_head(p_acc)
    if st_mark:
        print_csv_head(p_mk)

    # 10) 数据字典（根据当前 data-format 定义）
    print("\n[DATA DICTIONARY]")
    print("HR  表：time_lsl(s), t_device(s), bpm(次/分), device(字符串)")
    print("RR  表：time_lsl(s), t_device(s), ms(毫秒), device(字符串), seq(批序号，可空)")
    print("ECG 表：time_lsl(s), t_device(s), uV(微伏, 整数), device, seq(批序号), fs(Hz)")
    print("       注：ECG 为批量右对齐展开：若批长 n、采样率 fs，时间序列为 t_event-(n-1-i)/fs")
    print("ACC 表：time_lsl(s), t_device(s), x_mG, y_mG, z_mG(毫重力, 整数), device, seq, fs(Hz), range_g(±G)")
    print("MARK 表：time_lsl(s), label(标签), note(注释), packet_id(可空)")
    print("时间轴：默认使用 LSL 主机时间（--time-base lsl）。t_device 为设备侧时间，仅供对照。")

    print(f"\n[DONE] CSV 已写入：{out_dir}")

if __name__ == "__main__":
    main()
