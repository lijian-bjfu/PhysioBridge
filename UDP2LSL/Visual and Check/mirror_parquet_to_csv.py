#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mirror_parquet_to_csv.py —— 将 mirror_lsl_data/<SESSION>/ 内的 .parquet 批量导出为 CSV
- 默认转换最新会话；也可传入会话目录路径。
- 输出与输入同目录：在各 .parquet 旁生成同名规则的 .csv。
"""

import sys, json, argparse
from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]   # UDP2LSL/
MIRROR_ROOT = ROOT / "Data" / "mirror_lsl_data"

def parse_name_parts(name: str):
    """
    约定名形如 PB_<KIND>_<DEVICE>，例如 PB_ACC_H10 / PB_PPG_Verity
    返回 (kind_lower, device_lower)
    若不匹配，则尽量推断，否则 device 返回 'dev'
    """
    parts = (name or "").split("_")
    if len(parts) >= 3 and parts[0] == "PB":
        kind = parts[1].lower()
        device = parts[2].lower()
        return kind, device
    # 回退：kind 从第一个下划线段推断，device 用最后一段或 'dev'
    kind = (parts[0].lower() if parts else "stream")
    dev = (parts[-1].lower() if parts else "dev")
    return kind, dev


def find_latest_session(root: Path) -> Path | None:
    sessions = [p for p in root.iterdir() if p.is_dir() and p.name.startswith("S")]
    if not sessions:
        return None
    return sorted(sessions, key=lambda p: p.name)[-1]

def export_session(sess_dir: Path) -> int:
    idx_path = sess_dir / "session_index.json"
    if not idx_path.exists():
        print(f"[export] 缺少 {idx_path.name}，无法确定流信息。")
        return 0
    index = json.loads(idx_path.read_text(encoding="utf-8"))
    exported = 0
    for rec in index.get("streams", []):
        p = sess_dir / rec["file"]
        if not p.exists():
            print(f"[export][warn] 缺少文件 {p.name}，跳过。")
            continue
        try:
            df = pd.read_parquet(p)
        except Exception as e:
            print(f"[export][warn] 读取 {p.name} 失败：{e}")
            continue

        # 统一时间列名
        if "time_s" in df.columns:
            df = df.rename(columns={"time_s": "time_lsl"})

        name = rec.get("name") or ""
        stype = (rec.get("type") or "").upper()
        kind, dev = parse_name_parts(name)

        if stype == "ECG":
            if "ch_0" in df.columns:
                df = df[["time_lsl","ch_0"]].rename(columns={"ch_0":"uV"})
            out_name = f"{index['session']}_ecg_{dev}.csv"

        elif stype == "ACC":
            cols = ["time_lsl"] + [c for c in ["ch_0","ch_1","ch_2"] if c in df.columns]
            df = df[cols].rename(columns={"ch_0":"x_mG", "ch_1":"y_mG", "ch_2":"z_mG"})
            out_name = f"{index['session']}_acc_{dev}.csv"

        elif stype == "HR":
            if "ch_0" in df.columns:
                df = df[["time_lsl","ch_0"]].rename(columns={"ch_0":"bpm"})
            out_name = f"{index['session']}_hr_{dev}.csv"

        elif stype == "PPG":
            chs = [c for c in df.columns if c.startswith("ch_")]
            df = df[["time_lsl"] + chs]
            ren = {f"ch_{i}": f"ch{i+1}" for i in range(len(chs))}
            df = df.rename(columns=ren)
            out_name = f"{index['session']}_ppg_{dev}.csv"

        elif stype == "PPI":
            cols_order = ["ms","quality","blocker","skinContact","skinSupported","te"]
            have, ren = [], {}
            for i, key in enumerate(cols_order):
                ci = f"ch_{i}"
                if ci in df.columns:
                    have.append(ci); ren[ci] = key
            df = df[["time_lsl"] + have].rename(columns=ren)
            out_name = f"{index['session']}_ppi_{dev}.csv"

        elif stype == "RR":
            have, ren = [], {}
            if "ch_0" in df.columns: have.append("ch_0"); ren["ch_0"]="ms"
            if "ch_1" in df.columns: have.append("ch_1"); ren["ch_1"]="te"
            df = df[["time_lsl"] + have].rename(columns=ren)
            out_name = f"{index['session']}_rr_{dev}.csv"

        elif stype in ("MARKERS","MARKER","EVENTS"):
            if "value" in df.columns:
                df = df[["time_lsl","value"]].rename(columns={"value":"label"})
            out_name = f"{index['session']}_markers.csv"
        else:
            out_name = f"{index['session']}_{stype.lower()}_{dev}.csv"

        try:
            df.to_csv(sess_dir / out_name, index=False)
            exported += 1
            print(f"[export] -> {out_name}  rows={len(df)}")
        except Exception as e:
            print(f"[export][warn] 写入 {out_name} 失败：{e}")

    print(f"[export] 完成。文件数={exported}")
    return exported

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session_dir", nargs="?", help="会话目录路径（缺省则使用最新会话）")
    args = ap.parse_args()

    if args.session_dir:
        sess = Path(args.session_dir)
    else:
        sess = find_latest_session(MIRROR_ROOT)

    if not sess or not sess.exists():
        print("[export] 未找到可用会话目录。")
        sys.exit(1)

    print(f"[export] 目标会话：{sess}")
    export_session(sess)

if __name__ == "__main__":
    main()
