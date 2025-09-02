#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
比较 main_lsl_data 与 mirror_lsl_data 的一致性（心理生理实验友好版）
- 流覆盖一致性（是否录到同一批流）
- 以 Markers 为锚进行对齐（baseline_start/stop 必选；stim/intervention 次之）
- 统计特征一致性（mean/median/std/p5/p95/min/max，覆盖率）
- 时间合理性抽样快检（3 个窗口的极值时刻差/互相关滞后）
"""

from __future__ import annotations
import argparse, json, random, sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple, Optional

import numpy as np
import pandas as pd

# ---------- 路径策略 ----------
ROOT = Path(__file__).resolve().parents[1]   # UDP2LSL/
MAIN_ROOT   = ROOT / "Data" / "main_lsl_data"
MIRROR_ROOT = ROOT / "Data" / "mirror_lsl_data"

# 交互式选目录（可用则弹窗）
try:
    from tkinter import Tk, filedialog
except Exception:
    Tk = None; filedialog = None

def pick_dir_dialog(title: str, initial: Optional[Path] = None) -> Optional[Path]:
    if Tk is None or filedialog is None:
        print(f"[PROMPT] {title}")
        return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askdirectory(
        title=title,
        mustexist=True,
        initialdir=str(initial) if initial else None
    )
    root.destroy()
    return Path(p) if p else None


def find_latest_dir(root: Path) -> Optional[Path]:
    if not root.exists(): return None
    cands = [p for p in root.iterdir() if p.is_dir()]
    if not cands: return None
    # 名称常为 SYYYYMMDD-HHMMSS；时间越大越新
    return sorted(cands, key=lambda p: p.name)[-1]

# ---------- 命名与文件发现 ----------
def norm_kind_dev_from_name(path: Path) -> Tuple[str,str]:
    """
    从文件名尾部解析 kind/device：..._<kind>_<device>.csv
    markers 特例：返回 ("markers", "")
    """
    stem = path.stem.lower()
    if stem.endswith("_markers"): return "markers",""
    parts = stem.split("_")
    if len(parts) >= 3:
        kind = parts[-2]
        dev  = parts[-1]
        return kind, dev
    # 回退：尽力而为
    return "stream","dev"

def list_streams(dir_path: Path) -> Dict[Tuple[str,str], Path]:
    out: Dict[Tuple[str,str], Path] = {}
    for p in dir_path.glob("*.csv"):
        kind, dev = norm_kind_dev_from_name(p)
        out[(kind,dev)] = p
    return out

# ---------- Markers 匹配 ----------
CANON_MARKERS = {
    "baseline_start": ["baseline_start","baseline-start","baseline start"],
    "stim_start":     ["stim_start","stim-start","stim start","induction_start","induction-start","induction start"],
    "stim_end":       ["stim_end","stim-end","stim end","induction_end","induction-end","induction end"],
    "intervention_start": ["intervention_start","intervention-start","intervention start"],
    "intervention_end":   ["intervention_end","intervention-end","intervention end"],
    "stop":           ["stop","session_end","end","finish"],
}

def _canon(label: str) -> str:
    s = (label or "").strip().lower().replace("-", "_").replace(" ", "_")
    return s

def load_markers(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    # 兼容镜像 value->label 的导出
    if "label" not in df.columns and "value" in df.columns:
        df = df.rename(columns={"value": "label"})
    keep = [c for c in ["time_lsl","label"] if c in df.columns]
    return df[keep].copy()

def find_first_last(df: pd.DataFrame, aliases: List[str]) -> Tuple[Optional[float], Optional[float]]:
    if df.empty: return None, None
    lab = df["label"].astype(str).map(_canon)
    ts = df["time_lsl"].astype(float)
    ali = {_canon(x) for x in aliases}
    idx = [i for i, s in enumerate(lab) if s in ali]
    if not idx: return None, None
    arr = ts.iloc[idx].to_numpy()
    return float(arr.min()), float(arr.max())

# ---------- 统计特征 ----------
def stats_summary(df: pd.DataFrame, cols: List[str]) -> Dict[str, Dict[str, float]]:
    """
    返回 {col: {mean, median, std, p5, p95, min, max}}
    """
    out: Dict[str, Dict[str, float]] = {}
    for c in cols:
        x = pd.to_numeric(df[c], errors="coerce").dropna().to_numpy()
        if x.size == 0:
            out[c] = {k: float("nan") for k in ["mean","median","std","p5","p95","min","max"]}
            continue
        out[c] = {
            "mean":   float(np.mean(x)),
            "median": float(np.median(x)),
            "std":    float(np.std(x, ddof=0)),
            "p5":     float(np.percentile(x, 5)),
            "p95":    float(np.percentile(x,95)),
            "min":    float(np.min(x)),
            "max":    float(np.max(x)),
        }
    return out

def relative_diff(a: float, b: float) -> float:
    denom = max(1e-9, abs(a), abs(b))
    return abs(a - b) / denom

# ---------- 抽样窗口 ----------
def pick_overlap_window(dfA: pd.DataFrame, dfB: pd.DataFrame, min_len_s=10.0) -> Optional[Tuple[float,float]]:
    if dfA.empty or dfB.empty: return None
    t0 = max(dfA["time_lsl"].min(), dfB["time_lsl"].min())
    t1 = min(dfA["time_lsl"].max(), dfB["time_lsl"].max())
    if t1 - t0 < min_len_s: return None
    return float(t0), float(t1)

def sample_windows(t0: float, t1: float, n=3, win_len=8.0) -> List[Tuple[float,float]]:
    if t1 - t0 <= win_len: return [(t0, t1)]
    outs = []
    for _ in range(n):
        s = random.uniform(t0, t1 - win_len)
        outs.append((s, s + win_len))
    return outs

def window_extreme_lag(dfA: pd.DataFrame, dfB: pd.DataFrame, cols: List[str], w0: float, w1: float) -> Tuple[Optional[float], Optional[float]]:
    """
    返回：主/镜像“极值时刻差”的绝对值（ms）与“互相关滞后”估计（ms）
    为简单起见：对每列分别算极值时刻差，取其中位；相关滞后用 resample 到 20Hz 的互相关粗估。
    """
    ms = None; lag = None
    try:
        A = dfA[(dfA["time_lsl"]>=w0) & (dfA["time_lsl"]<=w1)].copy()
        B = dfB[(dfB["time_lsl"]>=w0) & (dfB["time_lsl"]<=w1)].copy()
        if A.empty or B.empty: return None, None
        diffs = []
        for c in cols:
            if c not in A.columns or c not in B.columns: continue
            ia = float(A.loc[A[c].idxmax(), "time_lsl"]) if not A[c].isna().all() else None
            ib = float(B.loc[B[c].idxmax(), "time_lsl"]) if not B[c].isna().all() else None
            ja = float(A.loc[A[c].idxmin(), "time_lsl"]) if not A[c].isna().all() else None
            jb = float(B.loc[B[c].idxmin(), "time_lsl"]) if not B[c].isna().all() else None
            cand = []
            if ia is not None and ib is not None: cand.append(abs(ia-ib))
            if ja is not None and jb is not None: cand.append(abs(ja-jb))
            if cand: diffs.append(np.median(cand))
        if diffs: ms = float(np.median(diffs) * 1000.0)
        # 互相关（粗）：时间对齐到 20Hz
        def to_20hz(df):
            s = pd.Series(df[cols[0]].to_numpy(), index=pd.to_datetime(df["time_lsl"], unit="s"))
            return s.resample("50L").mean().interpolate(limit=2).fillna(method="bfill").fillna(method="ffill")
        if cols and cols[0] in A.columns and cols[0] in B.columns:
            a = to_20hz(A); b = to_20hz(B)
            if len(a)>5 and len(b)>5:
                la = min(len(a), len(b))
                a = a.iloc[:la]; b = b.iloc[:la]
                xc = np.correlate(a-a.mean(), (b-b.mean())[::-1], mode="valid")
                k = int(np.argmax(xc))
                # 50ms 每格
                lag = float((k - 0) * 50.0)  # ms（粗估）
    except Exception:
        pass
    return ms, lag

# ---------- 主流程 ----------
@dataclass
class CompareResult:
    coverage_both: List[Tuple[str,str]]
    only_main: List[Tuple[str,str]]
    only_mirror: List[Tuple[str,str]]
    marker_diffs_ms: Dict[str, float]
    stats_table: List[Dict[str, object]]
    time_checks: List[Dict[str, object]]

def load_csv(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    if "time_lsl" in df.columns:
        df = df.sort_values("time_lsl").reset_index(drop=True)
    return df

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mirror", type=str, help="镜像会话目录（缺省=自动选择最新）")
    ap.add_argument("--main",   type=str, help="主线会话目录（缺省=弹窗选择；配合 --auto-main 可自动选择最新）")
    ap.add_argument("--auto-main", action="store_true", help="主线目录自动选择最新子目录")
    ap.add_argument("--windows", type=int, default=3, help="抽样窗口个数")
    ap.add_argument("--win-len", type=float, default=8.0, help="每个窗口长度（秒）")
    args = ap.parse_args()
    print("[RUN] compare_mirror_vs_main")
    print("      1) 检查流覆盖是否一致")
    print("      2) 以 markers 为锚对齐（若无则自动探测重叠窗口）")
    print("      3) 比较统计特征（mean/median/std/p5/p95/min/max、覆盖率）")
    print("      4) 时间合理性快检（抽样窗口的极值/相关滞后）")


    # 选择镜像会话
    print(f"[STEP] 寻找镜像会话目录：默认从 {MIRROR_ROOT} 选择最新（或使用 --mirror 指定）")
    if args.mirror:
        mirror_dir = Path(args.mirror)
    else:
        mirror_dir = find_latest_dir(MIRROR_ROOT)
    if not mirror_dir or not mirror_dir.exists():
        print("[ERROR] 未找到镜像会话目录"); sys.exit(1)
    else:
        print(f"[OK] 已选镜像会话：{mirror_dir}")

    # 选择主线会话
    print(f"[STEP] 寻找主线会话目录：默认在 {MAIN_ROOT}")
    if args.main:
        print("[INFO] 使用 --main 指定的目录。")
        main_dir = Path(args.main)
    else:
        if args.auto_main:
            print("[INFO] 使用 --auto-main：自动选择 main_lsl_data 下最新子目录。")
            main_dir = find_latest_dir(MAIN_ROOT)
        else:
            print("[PROMPT] 将弹出系统窗口：请选择“main_lsl_data/<会话>”目录。")
            main_dir = pick_dir_dialog("请选择主线会话目录（main_lsl_data/<会话>）", initial=MAIN_ROOT)
    if not main_dir or not main_dir.exists():
        print("[ERROR] 未找到主线会话目录"); sys.exit(1)
    else:
        print(f"[OK] 已选主线会话：{main_dir}")


    print(f"[PATH] main  : {main_dir}")
    print(f"[PATH] mirror: {mirror_dir}")

    A = list_streams(main_dir)
    B = list_streams(mirror_dir)

    both = sorted(list(set(A.keys()) & set(B.keys())))
    only_main = sorted(list(set(A.keys()) - set(B.keys())))
    only_mirror = sorted(list(set(B.keys()) - set(A.keys())))

    print("\n[1] 流覆盖一致性")
    print(f"  both       : {len(both)} 种")
    print(f"  only_main  : {len(only_main)} -> {only_main}")
    print(f"  only_mirror: {len(only_mirror)} -> {only_mirror}")
    if any(k[0] in ("ecg","markers") for k in only_main+only_mirror):
        print("  [FAIL] 核心流缺失（ECG/Markers）")
    elif only_main or only_mirror:
        print("  [WARN] 存在非核心流缺失")
    else:
        print("  [PASS] 两侧包含同一批流")

    # 2) Markers 对齐（若任一侧缺失，则降级为重叠窗口策略）
    print("\n[2] Markers 对齐检查")
    if ("markers","") in A: print(f"  [INFO] 主线 markers 文件：{A[('markers','')]}")
    else:                    print("  [INFO] 主线未找到 markers.csv")
    if ("markers","") in B: print(f"  [INFO] 镜像 markers 文件：{B[('markers','')]}")
    else:                    print("  [INFO] 镜像未找到 markers.csv")


    marker_diffs_ms: Dict[str, float] = {}
    def have_markers(D): return ("markers","") in D
    overlap_win: Optional[Tuple[float,float]] = None

    if have_markers(A) and have_markers(B):
        dfM = load_markers(A[("markers","")])
        dfR = load_markers(B[("markers","")])
        print(f"  [STEP] 评估 baseline_start / stop 的时间差（ms）")

        baseA,_ = find_first_last(dfM, CANON_MARKERS["baseline_start"])
        baseB,_ = find_first_last(dfR, CANON_MARKERS["baseline_start"])
        _, stopA = find_first_last(dfM, CANON_MARKERS["stop"])
        _, stopB = find_first_last(dfR, CANON_MARKERS["stop"])
        def diff_ms(x,y): 
            return abs(x-y)*1000.0 if (x is not None and y is not None) else float("nan")
        marker_diffs_ms["baseline_start"] = diff_ms(baseA, baseB)
        marker_diffs_ms["stop"]           = diff_ms(stopA, stopB)

        for k in ["stim_start","stim_end","intervention_start","intervention_end"]:
            a0,_ = find_first_last(dfM, CANON_MARKERS[k])
            b0,_ = find_first_last(dfR, CANON_MARKERS[k])
            marker_diffs_ms[k] = diff_ms(a0, b0)

        print("  差异(ms)：", {k: (None if np.isnan(v) else round(v,1)) for k,v in marker_diffs_ms.items()})
        ok_keys = ["baseline_start","stop"]
        ok = all((not np.isnan(marker_diffs_ms[k]) and marker_diffs_ms[k] <= 50.0) for k in ok_keys)
        warn = any((not np.isnan(marker_diffs_ms[k]) and marker_diffs_ms[k] > 50.0 and marker_diffs_ms[k] <= 200.0) for k in ok_keys)
        if ok:   print("  [PASS] 基础对齐达标（≤50 ms）")
        elif warn: print("  [WARN] 存在 50–200 ms 差异")
        else:   print("  [FAIL] baseline/stop 缺失或差异过大（>200 ms）")

        # 用 baseline/stop 夹出重叠窗口（若可）
        if baseA is not None and stopA is not None and baseB is not None and stopB is not None:
            overlap_win = (max(baseA,baseB), min(stopA,stopB))
            if overlap_win[1] - overlap_win[0] <= 0:
                overlap_win = None
    else:
        print("  [INFO] Markers 缺失或不完整，转用重叠时间窗口。")

    # 3) 统计特征（按流）
    print("\n[3] 统计特征一致性")
    rows_stats: List[Dict[str,object]] = []
    for kind,dev in both:
        if kind == "markers": 
            continue
        dfA = load_csv(A[(kind,dev)])
        dfB = load_csv(B[(kind,dev)])
        if dfA.empty or dfB.empty:
            rows_stats.append({"kind":kind,"dev":dev,"grade":"MISSING"})
            print(f"  {kind}|{dev}: [MISS] 空数据"); 
            continue

        # 限定重叠窗口
        if overlap_win is None:
            ow = pick_overlap_window(dfA, dfB, min_len_s=10.0)
            print(f"  [OK] 使用 baseline/stop 得到重叠窗口：{w0:.3f}–{w1:.3f}（{w1-w0:.1f}s）")
        else:
            ow = overlap_win
        if ow is None:
            rows_stats.append({"kind":kind,"dev":dev,"grade":"SKIP","note":"重叠不足"})
            print(f"  {kind}|{dev}: [SKIP] 重叠不足")
            continue
        w0,w1 = ow
        a = dfA[(dfA["time_lsl"]>=w0)&(dfA["time_lsl"]<=w1)].copy()
        b = dfB[(dfB["time_lsl"]>=w0)&(dfB["time_lsl"]<=w1)].copy()

        # 数值列
        num_cols = [c for c in a.columns if c!="time_lsl" and c in b.columns and c!="label"]
        S_A = stats_summary(a, num_cols)
        S_B = stats_summary(b, num_cols)

        # 覆盖率：用主侧 median_dt 估计 expected
        def median_dt(df):
            t = df["time_lsl"].to_numpy()
            if len(t)<3: return np.nan
            return float(np.median(np.diff(t)))
        dt = median_dt(a)
        dur = (w1-w0)
        expected = (dur/dt) if (dt and dt>0 and np.isfinite(dt)) else max(len(a),len(b))
        covA = len(a)/expected if expected>0 else float("nan")
        covB = len(b)/expected if expected>0 else float("nan")

        # 统计差：对每列各指标做相对差，然后取中位
        diffs = []
        for c in num_cols:
            for k in ["mean","median","std","p5","p95","min","max"]:
                diffs.append(relative_diff(S_A[c][k], S_B[c][k]))
        med_rel = float(np.nanmedian(diffs)) if diffs else float("nan")

        # 打分口径（ECG 严一点，HR 放松一点）
        if kind == "hr":
            pass_cond = (med_rel <= 0.03) and (abs((S_A[num_cols[0]]["median"])-(S_B[num_cols[0]]["median"])) <= 1.0)
        else:
            pass_cond = (med_rel <= 0.03)
        warn_cond = (med_rel <= 0.05)

        if pass_cond and abs(covA-covB) <= 0.03:
            grade = "PASS"
        elif warn_cond or abs(covA-covB) <= 0.05:
            grade = "WARN"
        else:
            grade = "FAIL"

        rows_stats.append({
            "kind":kind,"dev":dev,"grade":grade,
            "overlap_s": round(dur,2),
            "cov_main": round(covA,3), "cov_mirror": round(covB,3),
            "median_rel_diff": None if np.isnan(med_rel) else round(med_rel,4),
        })
        print(f"  {kind}|{dev}: {grade}  overlap={dur:.1f}s  cov={covA:.3f}/{covB:.3f}  Δrel≈{med_rel:.3f}")

    # 4) 时间合理性：抽样窗口极值/互相关快检
    print("\n[4] 时间快检（抽样窗口）")
    time_rows: List[Dict[str,object]] = []
    for kind,dev in both:
        if kind == "markers": continue
        dfA = load_csv(A[(kind,dev)])
        dfB = load_csv(B[(kind,dev)])
        ow = overlap_win or pick_overlap_window(dfA, dfB, min_len_s=10.0)
        if ow is None:
            continue
        w0,w1 = ow
        wins = sample_windows(w0, w1, n=args.windows, win_len=args.win_len)
        cols = [c for c in dfA.columns if c!="time_lsl" and c in dfB.columns and c!="label"]
        deltas = []; lags = []
        for w in wins:
            d_ms, lag_ms = window_extreme_lag(dfA, dfB, cols, w[0], w[1])
            if d_ms is not None: deltas.append(d_ms)
            if lag_ms is not None: lags.append(lag_ms)
        if deltas:
            d_med = float(np.median(deltas))
            # 判定口径
            if kind in ("ecg","acc","ppg"):
                g = "PASS" if d_med <= 20 else ("WARN" if d_med<=50 else "FAIL")
            else:  # hr/ppi/rr
                g = "PASS" if d_med <= 200 else ("WARN" if d_med<=400 else "FAIL")
            time_rows.append({"kind":kind,"dev":dev,"grade":g,"extreme_ms":round(d_med,1),
                              "lag_ms": None if not lags else round(float(np.median(lags)),1)})
            print(f"  {kind}|{dev}: {g}  extremeΔ≈{d_med:.1f} ms  xcorr lag≈{(np.median(lags) if lags else float('nan')):.1f} ms")

    # 写报告
    out_path = main_dir / "compare_report.txt"
    with out_path.open("w", encoding="utf-8") as f:
        f.write(f"main : {main_dir}\nmirror: {mirror_dir}\n\n")
        f.write("[1] 流覆盖一致性\n")
        f.write(f"both       : {len(both)}\n")
        f.write(f"only_main  : {only_main}\n")
        f.write(f"only_mirror: {only_mirror}\n\n")
        f.write("[2] Markers 对齐（ms）\n")
        for k,v in marker_diffs_ms.items():
            f.write(f"{k}: {('NA' if np.isnan(v) else round(v,1))}\n")
        f.write("\n[3] 统计特征一致性\n")
        for r in rows_stats:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
        f.write("\n[4] 时间快检\n")
        for r in time_rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"\n[DONE] 报告已写入：{out_path}")

if __name__ == "__main__":
    main()
