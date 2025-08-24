# -*- coding: utf-8 -*-
"""
plot_check_csv_validity_lite.py  (v3, robust filename & delimiter & columns detection)

- 无 pandas 依赖，仅用 csv + numpy + matplotlib
- 自动匹配文件名：包含关键词 'ecg' / 'hr' / 'rr' / 'marker' 皆可（不区分大小写）
- 自动侦测分隔符：Sniffer -> 逗号 -> 分号 -> Tab 多级回退
- 兼容更多列名别名：
  time:  time_lsl / time / timestamp / t_lsl / t / ts / timestamp_s
  ecg:   uV / uv / ecg_uV / ECG_uV / ecg / voltage / microvolts / voltage_uV
  hr:    bpm / hr / HR / heart_rate
  rr:    ms / rr_ms / rr / RR / ibi / ibi_ms
  mark:  label / name / event / marker / desc / value / text
- 控制台打印：找到的文件、侦测的分隔符、列名、前3行样例
- 输出：ecg.png / hr.png / rr.png / qa_report.txt
- 异常：写入 qa_error.log
"""

from __future__ import annotations
import os, sys, csv, math, argparse, traceback
from pathlib import Path
from typing import Dict, List, Tuple, Optional

import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# GUI 目录选择
try:
    import tkinter as tk
    from tkinter import filedialog
except Exception:
    tk = None

LOG_ERR = "qa_error.log"

# ----------------- 日志与选择 -----------------
def log_error(e: BaseException):
    msg = "".join(traceback.format_exception(type(e), e, e.__traceback__))
    Path(LOG_ERR).write_text(msg, encoding="utf-8")
    print(f"[ERROR] 异常写入 {LOG_ERR}\n{msg.splitlines()[-1]}")

def pick_directory_by_gui() -> Path:
    if tk is None:
        print("[WARN] tkinter 不可用，使用当前目录")
        return Path.cwd()
    root = tk.Tk(); root.withdraw(); root.update()
    d = filedialog.askdirectory(title="选择包含 CSV 的目录")
    root.update(); root.destroy()
    if not d:
        print("[ABORT] 取消选择"); sys.exit(0)
    return Path(d)

def parse_args() -> Path:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--dir", type=str, default=None)
    try:
        args, _ = ap.parse_known_args()
    except SystemExit:
        args = argparse.Namespace(dir=None)
    if args.dir:
        p = Path(args.dir).expanduser().resolve()
        if not p.exists():
            print(f"[ABORT] 目录不存在：{p}"); sys.exit(1)
        return p
    return pick_directory_by_gui()

# ----------------- 文件与解析 -----------------
def list_csv(folder: Path) -> List[Path]:
    files = sorted(folder.glob("*.csv"))
    print("[FILES]", ", ".join(p.name for p in files) if files else "(无 CSV)")
    return files

def pick_file_by_keywords(files: List[Path], keywords: List[str]) -> Optional[Path]:
    # 在文件名（不含扩展名）中查找任一关键词（不区分大小写）
    for p in files:
        name = p.stem.lower()
        if any(k in name for k in keywords):
            return p
    return None

def sniff_dialect(sample: str) -> Optional[csv.Dialect]:
    try:
        return csv.Sniffer().sniff(sample, delimiters=[",",";","\t","|"])
    except Exception:
        return None

def read_csv_dicts(path: Path) -> List[Dict[str,str]]:
    if not path or not path.exists(): return []
    raw = path.read_text(encoding="utf-8", errors="ignore")
    if raw.startswith("\ufeff"):
        raw = raw.lstrip("\ufeff")
    # 取样侦测
    sample = raw[:8192]
    dialect = sniff_dialect(sample)
    tried = []
    candidates = []
    if dialect is not None:
        candidates.append(dialect)
    # 回退顺序
    class _D: pass
    for delim in [",",";","\t"]:
        d = _D(); d.delimiter = delim; candidates.append(d)

    lines = raw.splitlines()
    if not lines: return []
    # 逐个候选尝试
    for d in candidates:
        delim = getattr(d, "delimiter", "?")
        tried.append(delim)
        try:
            reader = csv.DictReader(lines, delimiter=delim)
            rows = [{(k or "").strip(): (v or "").strip() for k,v in row.items()} for row in reader]
            # 要求至少解析出两列以上，否则视为失败
            if rows and len([c for c in rows[0].keys() if c != ""]) >= 2:
                print(f"[READ] {path.name}  delimiter='{delim}'  cols={list(rows[0].keys())}")
                # 打印前 3 行样例
                for i, r in enumerate(rows[:3]):
                    print("       row", i, r)
                return rows
        except Exception:
            continue
    print(f"[WARN] 无法解析：{path.name}  尝试分隔符={tried}")
    return []

def resolve_column(row_keys: List[str], candidates: List[str]) -> Optional[str]:
    lower = {k.lower(): k for k in row_keys}
    for c in candidates:
        if c.lower() in lower:
            return lower[c.lower()]
    return None

def to_float(s: str) -> Optional[float]:
    if s is None: return None
    s = s.strip()
    if not s: return None
    try:
        return float(s)
    except ValueError:
        # 常见逗号小数
        try:
            return float(s.replace(",", "."))
        except Exception:
            return None

# ----------------- 规范化加载 -----------------
TIME_CANDS = ["time_lsl","time","timestamp","t_lsl","t","ts","timestamp_s"]
ECG_CANDS  = ["uV","uv","ecg_uV","ECG_uV","ecg","voltage","microvolts","voltage_uV"]
HR_CANDS   = ["bpm","hr","HR","heart_rate"]
RR_CANDS   = ["ms","rr_ms","rr","RR","ibi","ibi_ms"]
SEQ_CANDS  = ["seq","sequence","packet_id","frame","index"]
FS_CANDS   = ["fs","sample_rate","samplerate","hz"]
MARK_CANDS = ["label","name","event","marker","desc","value","text"]

def load_one_series(path: Optional[Path],
                    time_candidates: List[str],
                    value_candidates: List[str]) -> Optional[dict]:
    if path is None: return None
    rows = read_csv_dicts(path)
    if not rows: return None
    keys = list(rows[0].keys())
    col_t = resolve_column(keys, time_candidates)
    col_v = resolve_column(keys, value_candidates)
    if not col_t or not col_v: 
        print(f"[WARN] 列名不匹配：{path.name}  keys={keys}")
        return None
    t, v = [], []
    for r in rows:
        ft = to_float(r.get(col_t)); fv = to_float(r.get(col_v))
        if ft is None or fv is None: continue
        t.append(ft); v.append(fv)
    if len(t) == 0:
        print(f"[WARN] 无有效数值：{path.name}")
        return None
    out = {"time": np.array(t, float), "value": np.array(v, float)}
    # 可选附加列
    col_seq = resolve_column(keys, SEQ_CANDS)
    if col_seq:
        seq = []
        for r in rows:
            fs = to_float(r.get(col_seq))
            seq.append(fs if fs is not None else np.nan)
        out["seq"] = np.array(seq, float)
    col_fs = resolve_column(keys, FS_CANDS)
    if col_fs:
        fsv = []
        for r in rows:
            ff = to_float(r.get(col_fs))
            if ff is not None: fsv.append(ff)
        out["fs"] = float(np.nanmedian(fsv)) if fsv else None
    return out

def load_markers(path: Optional[Path]) -> Optional[dict]:
    if path is None: return None
    rows = read_csv_dicts(path)
    if not rows: return None
    keys = list(rows[0].keys())
    col_t = resolve_column(keys, TIME_CANDS)
    col_l = resolve_column(keys, MARK_CANDS)
    if not col_t or not col_l: 
        print(f"[WARN] 标记列名不匹配：{path.name}  keys={keys}")
        return None
    t, lab = [], []
    for r in rows:
        ft = to_float(r.get(col_t))
        if ft is None: continue
        t.append(ft); lab.append(str(r.get(col_l,"")))
    if len(t) == 0:
        print(f"[WARN] 标记无有效时间：{path.name}")
        return None
    return {"time": np.array(t,float), "label": lab}

# ----------------- 统计与质检 -----------------
def estimate_fs_from_time(t: np.ndarray) -> Optional[float]:
    if t is None or len(t) < 3: return None
    dt = np.diff(t); dt = dt[dt > 0]
    if len(dt) == 0: return None
    return float(1.0/np.median(dt))

def check_ecg(ecg: dict, report: List[str]) -> dict:
    out = {"has_ecg": False}
    if not ecg: 
        report.append("ECG: 无数据"); return out
    t, u = ecg["time"], ecg["value"]
    out["has_ecg"] = True
    n = len(u); duration = float(np.nanmax(t) - np.nanmin(t)) if n else 0.0
    fs = ecg.get("fs") or estimate_fs_from_time(t)
    report.append(f"ECG: n={n}, 时长={duration:.3f}s, fs={fs if fs else '未知'}")
    out.update(n=n, duration=duration, fs=fs)

    if fs and duration > 0:
        expected = fs*duration
        completeness = n/expected if expected>0 else np.nan
        pass_comp = abs(completeness-1.0) <= 0.01
        report.append(f"  采样完整性: {completeness:.4f}  {'[PASS]' if pass_comp else '[FAIL] 超 ±1%'}")
        out["completeness"] = completeness
        out["pass_completeness"] = pass_comp

        dt = np.diff(t); dt = dt[dt>0]
        if len(dt) > 3:
            dt_mean, dt_std = float(np.mean(dt)), float(np.std(dt))
            ideal = 1.0/fs
            diff_pct = abs(dt_mean - ideal)/ideal if ideal>0 else np.nan
            pass_dt = diff_pct <= 0.01
            report.append(f"  时间一致性: Δt_mean={dt_mean:.6f}s, Δt_std={dt_std:.6f}s, ideal={ideal:.6f}s, 偏差={diff_pct*100:.2f}%  {'[PASS]' if pass_dt else '[WARN]'}")
            out.update(dt_mean=dt_mean, dt_std=dt_std, pass_dt=pass_dt)

    seq = ecg.get("seq", None)
    if isinstance(seq, np.ndarray) and len(seq) > 1 and np.isfinite(seq).any():
        d = np.diff(seq[np.isfinite(seq)])
        back = int(np.sum(d < 0)); jumps = int(np.sum(d > 1.5))
        report.append(f"  序号单调性: 回退={back}, 跳号={jumps}")
        out.update(seq_back=back, seq_jumps=jumps)
    return out

def check_hr_vs_rr(hr: dict, rr: dict, report: List[str]) -> dict:
    out = {"has_check": False}
    if not hr or not rr:
        report.append("HR vs RR: 数据不足"); return out
    th, hv = hr["time"], hr["value"]
    tr, rv = rr["time"], rr["value"]
    m = (rv>300)&(rv<3000); tr, rv = tr[m], rv[m]
    if len(tr)<3 or len(th)<3:
        report.append("HR vs RR: 重叠太短"); return out
    rr_hr = 60000.0/rv
    tmin, tmax = max(np.min(tr), np.min(th)), min(np.max(tr), np.max(th))
    mh = (th>=tmin)&(th<=tmax)
    th2, hr2 = th[mh], hv[mh]
    if len(th2)<3:
        report.append("HR vs RR: 重叠太短"); return out
    rr_interp = np.interp(th2, tr, rr_hr)
    diff = hr2 - rr_interp
    mean_err, mae = float(np.mean(diff)), float(np.mean(np.abs(diff)))
    report.append(f"HR vs RR: 平均误差={mean_err:+.2f} bpm, MAE={mae:.2f} bpm  {'[PASS ≤2 bpm]' if mae<=2.0 else '[WARN]'}")
    out.update(has_check=True, mean_err=mean_err, mae=mae)
    return out

def event_smoke(mark: dict, ecg: dict, hr: dict, report: List[str]) -> None:
    if not mark or "time" not in mark or "label" not in mark:
        report.append("EVENT：无标记或缺列，跳过。"); return
    labels = ["baseline_start","stim_start","stim_end","intervention_start","intervention_end"]

    def wmean(series: dict, t0: float, key: str, a: float, b: float):
        if not series or "time" not in series or key not in series: return None
        t = series["time"]; y = series[key]
        m = (t > t0 + a) & (t < t0 + b)
        if np.sum(m) < 3: return None
        return float(np.mean(y[m]))

    report.append("EVENT 烟雾测试（窗口：前2~5s 与 后2~5s）：")
    for lab in labels:
        idx = [i for i,l in enumerate(mark["label"]) if l == lab]
        if not idx: continue
        t0 = float(mark["time"][idx[0]])
        hr_pre = wmean(hr, t0, "value", -5, -2)
        hr_post = wmean(hr, t0, "value", +2, +5)
        ecg_pre = ecg_post = None
        if ecg and "value" in ecg:
            ecg_abs = {"time": ecg["time"], "value": np.abs(ecg["value"])}
            ecg_pre  = wmean(ecg_abs, t0, "value", -5, -2)
            ecg_post = wmean(ecg_abs, t0, "value", +2, +5)
        s = f"  - {lab}: "
        s += ("HR {:.2f}/{:.2f}/Δ{:+.2f} bpm".format(hr_pre, hr_post, hr_post-hr_pre)
              if (hr_pre is not None and hr_post is not None) else "HR N/A")
        s += " ; "
        s += ("|ECG| {:.2f}/{:.2f}/Δ{:+.2f} uV".format(ecg_pre, ecg_post, ecg_post-ecg_pre)
              if (ecg_pre is not None and ecg_post is not None) else "ECG N/A")
        report.append(s)

# ----------------- 绘图 -----------------
def draw_series(t, y, markers, out_png: Path, title: str, ylabel: str):
    if t is None or y is None or len(t)==0 or len(y)==0: 
        print(f"[PLOT] 跳过绘图（无数据）：{out_png.name}")
        return
    fig = plt.figure(figsize=(10,7)); ax = fig.add_subplot(111)
    if markers:
        for tt, lab in zip(markers.get("time",[]), markers.get("label",[])):
            ax.axvline(tt, alpha=0.25, zorder=0)
            ymax = np.nanmax(y) if np.isfinite(np.nanmax(y)) else 1.0
            ax.text(tt, ymax, str(lab), rotation=90, va="top", ha="left", fontsize=9, alpha=0.7)
    ax.plot(t, y, linewidth=1.2, zorder=5)
    ax.set_title(title); ax.set_xlabel("time_lsl (s)"); ax.set_ylabel(ylabel); ax.grid(True)
    fig.tight_layout(); fig.savefig(out_png); plt.close(fig)
    print(f"[PLOT] {out_png.name}")

# ----------------- 主流程 -----------------
def main():
    try:
        folder = parse_args()
        print(f"[DIR] {folder}")
        files = list_csv(folder)

        # 按关键词找文件（不要求精准文件名）
        f_ecg = pick_file_by_keywords(files, ["ecg"])
        f_hr  = pick_file_by_keywords(files, ["hr","heart"])
        f_rr  = pick_file_by_keywords(files, ["rr","ibi"])
        f_mk  = pick_file_by_keywords(files, ["marker","event","label"])

        print("[DETECT] ecg:", f_ecg.name if f_ecg else None)
        print("[DETECT] hr :", f_hr.name  if f_hr  else None)
        print("[DETECT] rr :", f_rr.name  if f_rr  else None)
        print("[DETECT] mks:", f_mk.name  if f_mk  else None)

        # 读取与规范化
        ecg = load_one_series(f_ecg, TIME_CANDS, ECG_CANDS)
        if ecg:  # ecg.value 命名更语义化
            ecg["uV"] = ecg["value"]

        hr  = load_one_series(f_hr,  TIME_CANDS, HR_CANDS)
        rr  = load_one_series(f_rr,  TIME_CANDS, RR_CANDS)
        mk  = load_markers(f_mk)

        report: List[str] = [f"CSV 目录: {folder}", ""]
        ecg_stat = check_ecg(ecg, report); report.append("")
        _ = check_hr_vs_rr(hr, rr, report); report.append("")
        event_smoke(mk, ecg, hr, report); report.append("")

        # 绘图
        if ecg:
            fs = ecg_stat.get("fs", float("nan"))
            draw_series(ecg["time"], ecg["uV"], mk, folder/"ecg.png",
                        f"ECG (uV) vs time | fs={fs:.1f} Hz" if isinstance(fs,(int,float)) and math.isfinite(fs) else "ECG (uV) vs time",
                        "ECG (uV)")
        if hr:
            draw_series(hr["time"], hr["value"], mk, folder/"hr.png", "HR (bpm) vs time", "HR (bpm)")
        if rr:
            draw_series(rr["time"], rr["value"], mk, folder/"rr.png", "RR interval (ms) vs time", "RR (ms)")

        Path(folder/"qa_report.txt").write_text("\n".join(report), encoding="utf-8")
        print("[REPORT] 已生成 qa_report.txt")
        print("\n".join(report))

    except Exception as e:
        log_error(e)
        print("脚本异常中止，查看 qa_error.log 获取详情。")

if __name__ == "__main__":
    main()
