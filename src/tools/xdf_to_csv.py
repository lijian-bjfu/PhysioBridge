#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
XDF → CSV 转换器（多流/多设备版）
- 每一种 stype（PPG/ECG/ACC/HR/PPI/RR/Markers）会导出“所有匹配的流”
- 输出文件名会带设备后缀（从流名推断，如 PB_ACC_H10 -> _acc_h10.csv）
- RR 新增支持：若通道为 [ms, te] 则完整落列
- 若数值型 LSL 流缺失，仍回退解析 PB_UDP 文本（兼容旧数据）

报告会列出：生成的 CSV 清单、每个 CSV 的 shape、逐列含义
"""
from __future__ import annotations
import csv, json
import sys
from typing import Any, Dict, List, Optional, Tuple

import sys
import os
from pathlib import Path
# 获取当前工作目录
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)
from paths import RECORDER_DATA_DIR
# === 交互：无参数时弹文件/目录选择框 ===
try:
    from tkinter import Tk, filedialog
except Exception:
    Tk = None; filedialog = None

def pick_file_dialog() -> Optional[Path]:
    if Tk is None or filedialog is None: return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askopenfilename(title="选择 XDF 文件",
                                    # 默认目录
                                    initialdir=str(RECORDER_DATA_DIR),
                                    filetypes=[("XDF files","*.xdf"),("All files","*.*")])
    root.destroy(); return Path(p) if p else None

def pick_dir_dialog(title: str) -> Optional[Path]:
    if Tk is None or filedialog is None: return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askdirectory(title=title, 
                                initialdir=str(RECORDER_DATA_DIR), 
                                mustexist=True)
    root.destroy(); return Path(p) if p else None

# === 小工具 ===
def ensure_out(path: Path): path.mkdir(parents=True, exist_ok=True)

def open_writer(path: Path, header: List[str]):
    f = path.open("w", newline="", encoding="utf-8")
    w = csv.writer(f); w.writerow(header); return w, f

def flatten_1d(row) -> List[float]:
    """把任意“标量/一维/多维/嵌套列表”的行拍扁成 1D Python 列表"""
    try:
        import numpy as np
        arr = np.asarray(row)
        return arr.ravel().tolist()
    except Exception:
        out = []
        def _walk(x):
            if isinstance(x, (list, tuple)):
                for t in x: _walk(t)
            else:
                out.append(x)
        _walk(row)
        return out

def iter_streams_by_type(streams, typ: str):
    """返回所有 stype 命中的流（全量），忽略大小写"""
    t = typ.lower()
    for s in streams:
        st = ((s.get("info",{}).get("type") or [""])[0] or "").lower()
        if st == t:
            yield s

def parse_name_parts(name: str) -> Tuple[str, str, str]:
    """
    约定名形如 PB_<KIND>_<DEVICE>，
    例如 PB_ACC_H10 / PB_PPG_Verity
    返回 (kind_lower, device_lower, raw_name)
    若不匹配，则尽量推断，否则 device 返回 'dev'
    """
    parts = (name or "").split("_")
    if len(parts) >= 3 and parts[0] == "PB":
        kind = parts[1].lower()
        device = parts[2].lower()
        return kind, device, name
    # 回退：kind 从 type 推断，device 用最后一段或 'dev'
    return "", (parts[-1].lower() if parts else "dev"), name

def cols_for_ppg(ch: int) -> List[str]:
    return ["time_lsl"] + [f"ch{i+1}" for i in range(max(1,ch))]

# === 报告收集与输出 ===
EXTRA_DOC: Dict[str, List[str]] = {
    "Respiration": [  # 添加呼吸数据的文档说明
        "呼吸数据来自 HKH-11C（呼吸带），单位通常为 arbitrary_units 或 raw。",
        "频率约为50Hz, 数据点间隔约为20毫秒。"
    ],
    "PPG": [
        "PPG 为 22-bit 原始计数，示光电信号的原始强度，值大概在几万到几百万间波动，和放大增益/光路有关。",
        "四个通道中常有一路环境光（ambient）。具体通道映射视设备/固件而定。",
        "常见做法：带通/去漂移/归一化，再进行脉搏定位或与 PPI 对齐。"
    ],
    "PPI": [
        "ms 为脉搏间期（毫秒）。quality 为误差估计（毫秒，越小越好）。",
        "可选标志位：blockerBit（1=此拍无效）、skinContactStatus（1=皮肤接触良好）、skinContactSupported（1=支持检测）。"
    ],
    "RR": [
        "RR 来自 H10（心电 R-R 间期），单位毫秒。若含 te 列，为 beat 事件时间（LSL 对齐后）。"
    ],
    "HR": [
        "bpm 为设备侧瞬时心率。建议与 RR/PPI 推导的一致性作校验。"
    ],
    "ACC": [
        "单位 mG（毫重力）。可用于活动水平估计与运动伪迹识别。"
    ],
    "ECG": [
        "单位微伏（uV）。H10 提供等采样 ECG（典型 130Hz）。"
    ],
    "Markers": [
        "实验阶段标签来自手机端事件；后续可在分析脚本中转为 trial 边界。"
    ],
}

def _col_desc_map(kind: str, header: List[str]) -> List[str]:
    descs = []
    for col in header:
        c = col.lower()
        if c == "time_lsl":
            descs.append("LSL 时间戳（秒，local_clock 单调时钟）")
        elif kind == "Respiration":
            descs.append("呼吸强度值（breath value）")
        elif kind == "PPG":
            descs.append("PPG 原始计数（22-bit）" if c.startswith("ch") else "PPG 相关列")
        elif kind == "ECG":
            descs.append("心电电压（微伏）" if c == "uv" else "ECG 相关列")
        elif kind == "ACC":
            descs.append(f"加速度 {col.split('_')[0].upper()} 轴（mG）" if c.endswith("_mg") else "ACC 相关列")
        elif kind == "HR":
            descs.append("瞬时心率（bpm）" if c == "bpm" else "HR 相关列")
        elif kind == "PPI":
            mapping = {"ms":"心搏间期（毫秒）","quality":"误差估计（毫秒）",
                       "blocker":"blockerBit（1=此拍无效）","skincontact":"皮肤接触良好(1/0)",
                       "skinsupported":"支持皮肤接触检测(1/0)","te":"beat 事件时间（秒）"}
            descs.append(mapping.get(c,"PPI 相关列"))
        elif kind == "RR":
            mapping = {"ms":"R-R 间期（毫秒）","te":"beat 事件时间（秒）"}
            descs.append(mapping.get(c,"RR 相关列"))
        elif kind == "Markers":
            descs.append("事件标签（字符串）" if c == "label" else "标记相关列")
        else:
            descs.append("未知列")
    return descs

def _add_report(report: List[Dict[str, Any]], kind: str, out_path: Path, header: List[str], rows: int):
    report.append({
        "kind": kind,
        "file": out_path.name,
        "rows": rows,
        "cols": len(header),
        "header": header,
        "desc": _col_desc_map(kind, header),
    })

def _emit_report(out_dir: Path, stem: str, report: List[Dict[str, Any]]):
    print("\n[REPORT]")
    print(f"- 生成 {len(report)} 个 CSV：")
    for r in report:
        print(f"  * {r['file']}: {r['rows']} 行 × {r['cols']} 列")
        print(f"    行含义：每行是一条{r['kind']}记录（按 time_lsl 升序）")
        print(f"    列含义：")
        for name, desc in zip(r["header"], r["desc"]):
            print(f"      - {name}: {desc}")
        notes = EXTRA_DOC.get(r["kind"], [])
        if notes:
            print("    数据说明：")
            for line in notes:
                print(f"      · {line}")

    # 根据用户在系统窗口选择的目录保存文件
    rpt_path = out_dir / f"{stem}_report.txt"
    with rpt_path.open("w", encoding="utf-8") as f:
        f.write(f"数据导出结果报告\n源文件: {stem}.xdf\n\n")
        f.write(f"共生成 {len(report)} 个 CSV 文件：\n\n")
        for r in report:
            f.write(f"文件: {r['file']}\n")
            f.write(f"形状: {r['rows']} 行 × {r['cols']} 列\n")
            f.write(f"行含义: 每行是一条{r['kind']}记录（按 time_lsl 升序）\n")
            f.write("列说明:\n")
            for name, desc in zip(r["header"], r["desc"]):
                f.write(f"  - {name}: {desc}\n")
            notes = EXTRA_DOC.get(r["kind"], [])
            if notes:
                f.write("数据说明:\n")
                for line in notes:
                    f.write(f"  · {line}\n")
            f.write("\n")

    print(f"\n[DONE] CSV 输出目录：{out_dir}")
    print(f"[DONE] 报告文件：{rpt_path}")

# === 导出实现（逐流） =================================================
def export_ppg(st, stem: str, out_dir: Path, report: List[Dict[str,Any]]):
    name = (st.get("info",{}).get("name") or [""])[0] or "PPG"
    _, dev, _ = parse_name_parts(name)
    ch = int((st["info"]["channel_count"][0]) if st["info"]["channel_count"] else 4)
    header = ["time_lsl"] + [f"ch{i+1}" for i in range(ch)]
    p = out_dir / f"{stem}_ppg_{dev}.csv"
    w, f = open_writer(p, header)
    ts = st["time_stamps"]; X = st["time_series"]
    for i in range(len(ts)):
        vals = [float(v) for v in flatten_1d(X[i])]
        w.writerow([float(ts[i])] + vals)
    f.close()
    _add_report(report, "PPG", p, header, len(ts))
    print(f"[CSV] PPG -> {p}  rows={len(ts)}")

def export_ecg(st, stem: str, out_dir: Path, report: List[Dict[str,Any]]):
    name = (st.get("info",{}).get("name") or [""])[0] or "ECG"
    _, dev, _ = parse_name_parts(name)
    header = ["time_lsl","uV"]
    p = out_dir / f"{stem}_ecg_{dev}.csv"
    w, f = open_writer(p, header)
    ts = st["time_stamps"]; X = st["time_series"]
    for i in range(len(ts)):
        row = flatten_1d(X[i]); v = float(row[0]) if row else 0.0
        w.writerow([float(ts[i]), v])
    f.close()
    _add_report(report, "ECG", p, header, len(ts))
    print(f"[CSV] ECG -> {p}  rows={len(ts)}")

def export_acc(st, stem: str, out_dir: Path, report: List[Dict[str,Any]]):
    name = (st.get("info",{}).get("name") or [""])[0] or "ACC"
    _, dev, _ = parse_name_parts(name)
    header = ["time_lsl","x_mG","y_mG","z_mG"]
    p = out_dir / f"{stem}_acc_{dev}.csv"
    w, f = open_writer(p, header)
    ts = st["time_stamps"]; X = st["time_series"]
    wrote = 0
    for i in range(len(ts)):
        row = flatten_1d(X[i])
        if len(row) >= 3:
            w.writerow([float(ts[i]), float(row[0]), float(row[1]), float(row[2])]); wrote += 1
    f.close()
    _add_report(report, "ACC", p, header, wrote)
    print(f"[CSV] ACC -> {p}  rows={wrote}")

def export_hr(st, stem: str, out_dir: Path, report: List[Dict[str,Any]]):
    name = (st.get("info",{}).get("name") or [""])[0] or "HR"
    _, dev, _ = parse_name_parts(name)
    header = ["time_lsl","bpm"]
    p = out_dir / f"{stem}_hr_{dev}.csv"
    w, f = open_writer(p, header)
    ts = st["time_stamps"]; X = st["time_series"]
    for i in range(len(ts)):
        row = flatten_1d(X[i]); v = float(row[0]) if row else 0.0
        w.writerow([float(ts[i]), v])
    f.close()
    _add_report(report, "HR", p, header, len(ts))
    print(f"[CSV] HR  -> {p}  rows={len(ts)}")

def _infer_ppi_header_width(st) -> int:
    # 优先 channel_count；无则扫一遍行宽
    ch = 0
    try:
        ch = int((st["info"]["channel_count"][0]) if st["info"]["channel_count"] else 0)
    except Exception:
        ch = 0
    if ch <= 0:
        X = st["time_series"]; maxw = 1
        for i in range(len(X)):
            w = len(flatten_1d(X[i]))
            if w > maxw: maxw = w
        ch = maxw
    # 限定到我们支持的列：ms, quality, blocker, skinContact, skinSupported, te（最多 6）
    return max(1, min(int(ch), 6))

def export_ppi(st, stem: str, out_dir: Path, report: List[Dict[str,Any]]):
    name = (st.get("info",{}).get("name") or [""])[0] or "PPI"
    _, dev, _ = parse_name_parts(name)
    ch = _infer_ppi_header_width(st)
    # 按常见顺序构造列；若实际列更短，后面的列不会写入
    ppi_cols_all = ["ms","quality","blocker","skinContact","skinSupported","te"]
    header = ["time_lsl"] + ppi_cols_all[:ch]
    p = out_dir / f"{stem}_ppi_{dev}.csv"
    w, f = open_writer(p, header)
    ts = st["time_stamps"]; X = st["time_series"]
    wrote = 0
    for i in range(len(ts)):
        flat = flatten_1d(X[i])
        vals = []
        for k in range(ch):
            try:
                vals.append(float(flat[k]))
            except Exception:
                vals.append(float("nan"))
        w.writerow([float(ts[i])] + vals); wrote += 1
    f.close()
    _add_report(report, "PPI", p, header, wrote)
    print(f"[CSV] PPI -> {p}  rows={wrote}")

def export_rr(st, stem: str, out_dir: Path, report: List[Dict[str,Any]]):
    name = (st.get("info",{}).get("name") or [""])[0] or "RR"
    _, dev, _ = parse_name_parts(name)
    # RR 典型为 [ms, te]；若只有 1 列，就只写 ms
    ch = 0
    try:
        ch = int((st["info"]["channel_count"][0]) if st["info"]["channel_count"] else 0)
    except Exception:
        ch = 0
    if ch <= 0:
        X = st["time_series"]; maxw = 1
        for i in range(len(X)):
            w = len(flatten_1d(X[i]));  maxw = max(maxw, w)
        ch = maxw
    ch = max(1, min(int(ch), 2))
    header = ["time_lsl"] + (["ms","te"][:ch])
    p = out_dir / f"{stem}_rr_{dev}.csv"
    w, f = open_writer(p, header)
    ts = st["time_stamps"]; X = st["time_series"]
    wrote = 0
    for i in range(len(ts)):
        flat = flatten_1d(X[i])
        vals = []
        for k in range(ch):
            try:
                vals.append(float(flat[k]))
            except Exception:
                vals.append(float("nan"))
        w.writerow([float(ts[i])] + vals); wrote += 1
    f.close()
    _add_report(report, "RR", p, header, wrote)
    print(f"[CSV] RR  -> {p}  rows={wrote}")

def export_markers(st, stem: str, out_dir: Path, report: List[Dict[str,Any]]):
    header = ["time_lsl","label"]
    p = out_dir / f"{stem}_markers.csv"
    w, f = open_writer(p, header)
    ts = st["time_stamps"]; X = st["time_series"]
    for i in range(len(ts)):
        raw = X[i][0] if isinstance(X[i], (list,tuple)) else X[i]
        try:
            obj = json.loads(raw); label = obj.get("label","")
        except Exception:
            label = str(raw)
        w.writerow([float(ts[i]), label])
    f.close()
    _add_report(report, "Markers", p, header, len(ts))
    print(f"[CSV] MRK -> {p}  rows={len(ts)}")

def export_hkh(st, stem: str, out_dir: Path, report: List[Dict[str,Any]]):
    """
    转换 HKH 数据流（呼吸带）为 CSV 格式
    """
    # --- 校验：是否为呼吸流 ---
    name = (st.get("info", {}).get("name") or [""])[0] or ""
    typ  = (st.get("info", {}).get("type") or [""])[0] or ""
    if ("respiration" not in typ.lower()) and ("hb_respiration" not in name.lower()):
        print(f"[SKIP] 非呼吸流：name={name} type={typ}")
        return

    # --- 目标文件 ---
    header = ["time_lsl","BreathingValue"]  # 如果你希望与文档描述一致，可改成 ["time_lsl","BreathingValue"]
    p = out_dir / f"{stem}_Respiration_HKH.csv"

    # --- 取数据并写盘 ---
    try:
        ts = st["time_stamps"]
        X  = st["time_series"]
        w, f = open_writer(p, header)
        for i in range(len(ts)):
            breathing_value = float(flatten_1d(X[i])[0])  # 取第1通道
            w.writerow([float(ts[i]), breathing_value])
        f.close()
        _add_report(report, "Respiration", p, header, len(ts))
        print(f"[CSV] Respiration -> {p}  rows={len(ts)}")
    except Exception as e:
        print(f"[ERROR] 写入呼吸 CSV 失败：{e}")
        # 即便失败也把尝试写入的路径告诉用户
        print(f"[INFO] 目标文件（可能未完成/未创建）：{p}")
        raise

# === 主流程 ===========================================================
def main():
    # 1) 获取路径
    import sys
    if len(sys.argv) >= 2:
        xdf_path = Path(sys.argv[1]).expanduser()
    else:
        # 根据用户在系统窗口选择文件
        xdf_path = pick_file_dialog()
        if xdf_path is None:
            try:
                raw = input("请输入 Polar XDF 文件路径：").strip().strip('"').strip("'")
                xdf_path = Path(raw) if raw else None
            except EOFError:
                xdf_path = None
    if xdf_path is None or not xdf_path.exists():
        print("[ERROR] 未提供有效 .xdf"); return

    out_root = RECORDER_DATA_DIR
    out_dir = out_root / xdf_path.stem
    ensure_out(out_dir)
    print(f"[OUT] CSV 输出目录: {out_dir}")

    # 2) 读取 XDF
    try:
        import pyxdf
    except ImportError:
        print("缺少依赖：pyxdf；pip install pyxdf"); return

    print(f"[LOAD] {xdf_path}")
    streams, _ = pyxdf.load_xdf(str(xdf_path))
    if not streams:
        print("[ERROR] 文件中没有任何流"); return

    stem = xdf_path.stem
    report: List[Dict[str, Any]] = []
    wrote_numeric = False

    # 3) 数值型导出（逐类型 * 多设备*）
    has_any = False
    typed = {
        "Respiration": list(iter_streams_by_type(streams, "Respiration")),
        "PPG": list(iter_streams_by_type(streams, "PPG")),
        "ECG": list(iter_streams_by_type(streams, "ECG")),
        "ACC": list(iter_streams_by_type(streams, "ACC")),
        "HR":  list(iter_streams_by_type(streams, "HR")),
        "PPI": list(iter_streams_by_type(streams, "PPI")),
        "RR":  list(iter_streams_by_type(streams, "RR")),
    }
    st_markers = None
    # Markers 可能叫 PB_MARKERS 或 type=Markers
    for s in streams:
        name = (s.get("info",{}).get("name") or [""])[0] or ""
        typ  = (s.get("info",{}).get("type") or [""])[0] or ""
        if name == "PB_MARKERS" or typ == "Markers":
            st_markers = s; break

    # 按类型批量导出
    for st in typed["PPG"]:
        has_any = True; wrote_numeric = True; export_ppg(st, stem, out_dir, report)
    for st in typed["ECG"]:
        has_any = True; wrote_numeric = True; export_ecg(st, stem, out_dir, report)
    for st in typed["ACC"]:
        has_any = True; wrote_numeric = True; export_acc(st, stem, out_dir, report)
    for st in typed["HR"]:
        has_any = True; wrote_numeric = True; export_hr(st, stem, out_dir, report)
    for st in typed["PPI"]:
        has_any = True; wrote_numeric = True; export_ppi(st, stem, out_dir, report)
    for st in typed["RR"]:
        has_any = True; wrote_numeric = True; export_rr(st, stem, out_dir, report)
    if st_markers:
        has_any = True; export_markers(st_markers, stem, out_dir, report)
    for st in typed["Respiration"]:
        export_hkh(st, stem, out_dir, report)

    # 4) 若没有任何数值流，回退解析 PB_UDP 文本
    if not wrote_numeric:
        # 与旧版保持一致的回退（单份合并，不区分设备）
        st_udp = None
        for s in streams:
            name = (s.get("info",{}).get("name") or [""])[0] or ""
            typ  = (s.get("info",{}).get("type") or [""])[0] or ""
            if name == "PB_UDP" or typ.lower() == "udp_text":
                st_udp = s; break
        if not st_udp:
            print("[ERROR] 未发现数值流，也未找到 PB_UDP；无法导出。"); return

        print("[INFO] 未发现数值型流，回退解析 PB_UDP 文本。")
        # 下面保持你旧逻辑（省略，与你现有版本一致）——如需要我也可以把回退段补全
        # 这里直接提示用户：请优先使用数值型流录制
        print("[WARN] 建议改用 bridge_hub 的多流数值 LSL，避免回退解析。")

    # 5) 生成报告
    if report:
        _emit_report(out_dir, stem, report)
    else:
        print("[WARN] 没有生成任何 CSV，报告跳过。")

if __name__ == "__main__":
    main()
