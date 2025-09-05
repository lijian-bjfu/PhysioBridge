#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_xdf.py — 通用 XDF 结构体检器（纯只读，不导出 CSV）

目的：快速判定录制“结构是否合格”（有哪些流、类型/通道/样本数/时长），
并按期望表给出 PASS/FAIL。用于你确认“5 条独立 LSL 流”是否真的录进 XDF。

用法：
- 直接 Run；无参数会弹出文件选择框。
- 或：python check_xdf.py /path/to/file.xdf
"""

from __future__ import annotations
import os, sys
from typing import Any, Dict, List, Optional

from pathlib import Path
# 获取当前工作目录
project_root = os.getcwd()

# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from paths import RECORDER_DATA_DIR
# === 交互：无参数时弹文件/目录选择框 ===

# ============== 配置区：期望的流清单（按 type 匹配，name 子串可选） ==================
EXPECTED: List[Dict[str, Any]] = [
    # 你这次的实验：Verity 勾选了 PPG/PPI/HR，再加 Markers。PB_UDP 可选。
    {"hint_type": "PPG",     "hint_name_contains": [], "required": True,  "min_duration": 8.0, "min_samples": 200},
    {"hint_type": "PPI",     "hint_name_contains": [], "required": True,  "min_events": 5},
    {"hint_type": "HR",      "hint_name_contains": [], "required": True,  "min_events": 5},
    {"hint_type": "Markers", "hint_name_contains": [], "required": True,  "min_events": 3},
    # 若你也想强制 PB_UDP 存在，取消下一行注释：
    # {"hint_type": "udp_text","hint_name_contains": ["pb_udp"], "required": False},
]
# 是否允许“未在期望表声明”的其它流存在（通常 True）
ALLOW_EXTRA_STREAMS = True
# ==============================================================================

# —— GUI 选文件（保留你原来的体验）——
try:
    from tkinter import Tk, filedialog
except Exception:
    Tk = None
    filedialog = None

def pick_file_dialog() -> Optional[str]:
    if Tk is None or filedialog is None:
        return None
    root = Tk(); root.withdraw(); root.update()
    p = filedialog.askopenfilename(title="选择 XDF 文件",
                                    # 默认目录
                                    initialdir=str(RECORDER_DATA_DIR),
                                    filetypes=[("XDF files","*.xdf"),("All files","*.*")])
    root.destroy()
    return p or None

# —— 辅助提取函数 —— 
def _name(s) -> str:
    return (s.get("info",{}).get("name") or [""])[0] or ""

def _type(s) -> str:
    return (s.get("info",{}).get("type") or [""])[0] or ""

def _ch_count(s) -> int:
    try:
        return int((s.get("info",{}).get("channel_count") or [0])[0])
    except Exception:
        return 0

def _srate(s) -> float:
    try:
        return float((s.get("info",{}).get("nominal_srate") or [0])[0])
    except Exception:
        return 0.0

def _span(s) -> float:
    ts = s.get("time_stamps", [])
    return float(ts[-1] - ts[0]) if len(ts) >= 2 else 0.0

def _samples(s) -> int:
    return int(len(s.get("time_series", [])))

def _match_stream(streams, hint_type: Optional[str], hint_names: List[str]):
    """按 type 优先、name 包含次之，返回跨度最长的一条"""
    cand = []
    for st in streams:
        typ = (_type(st) or "").lower()
        nam = (_name(st) or "").lower()
        ok = False
        if hint_type and typ == hint_type.lower():
            ok = True
        if not ok and hint_names:
            if any(h.lower() in nam for h in hint_names):
                ok = True
        if ok:
            cand.append(st)
    if not cand:
        return None
    return max(cand, key=_span)

def main():
    # 1) 取路径
    if len(sys.argv) >= 2:
        path = sys.argv[1]
    else:
        path = pick_file_dialog() or input("请输入 XDF 文件路径：").strip()

    if not path or not os.path.isfile(path):
        print(f"[ERROR] 文件不存在：{path}")
        sys.exit(1)

    # 2) 读 XDF
    try:
        import pyxdf
    except ImportError:
        print("缺少依赖：pyxdf；请执行 pip install pyxdf")
        sys.exit(1)

    try:
        streams, _ = pyxdf.load_xdf(path)
    except Exception as e:
        print(f"[ERROR] 读取 XDF 失败：{e}")
        sys.exit(1)

    print(f"[FILE] {path}")
    if not streams:
        print("[FAIL] 文件中没有任何流")
        print("[RESULT] NOT PASS"); sys.exit(1)

    # 3) 打印总清单
    print("[STREAMS] 全量清单：")
    for s in streams:
        print("  - name='{n}' | type='{t}' | ch={c} | srate={sr} | samples={k} | span={sp:.2f}s"
              .format(n=_name(s), t=_type(s), c=_ch_count(s), sr=_srate(s),
                      k=_samples(s), sp=_span(s)))

    # 4) 逐项验收
    pass_all = True
    used_ids = set()
    print("\n[CHECK] 逐项校验：")
    for i, exp in enumerate(EXPECTED, start=1):
        st = _match_stream(streams, exp.get("hint_type"), exp.get("hint_name_contains", []))
        need = bool(exp.get("required", False))
        if st is None:
            print(f"  #{i} type={exp.get('hint_type')} name~{exp.get('hint_name_contains', [])} -> MISSING" + (" [REQUIRED]" if need else ""))
            if need: pass_all = False
            continue

        used_ids.add(id(st))
        name, typ = _name(st), _type(st)
        span, cnt = _span(st), _samples(st)
        ok = True; why = []

        if "min_duration" in exp and span < float(exp["min_duration"]):
            ok = False; why.append(f"时长 {span:.2f}s < {exp['min_duration']}")
        # 对于事件流，样本数就是“事件数”
        if "min_samples" in exp and cnt < int(exp["min_samples"]):
            ok = False; why.append(f"样本数 {cnt} < {exp['min_samples']}")
        if "min_events" in exp and cnt < int(exp["min_events"]):
            ok = False; why.append(f"事件数 {cnt} < {exp['min_events']}")

        state = "PASS" if ok else "FAIL"
        if not ok and need: pass_all = False
        extra = f" ({'; '.join(why)})" if why else ""
        print(f"  #{i} '{name}' [{typ}] span={span:.2f}s samples={cnt} -> {state}{extra}")

    # 5) 额外提示：未在期望中声明的流
    if ALLOW_EXTRA_STREAMS:
        extras = [s for s in streams if id(s) not in used_ids]
        if extras:
            print("\n[INFO] 未在期望表中的其它流（仅提示）：")
            for s in extras:
                print(f"  - name='{_name(s)}' type='{_type(s)}' span={_span(s):.2f}s samples={_samples(s)}")

    print("\n[RESULT] PASS" if pass_all else "\n[RESULT] NOT PASS")
    sys.exit(0 if pass_all else 1)

if __name__ == "__main__":
    main()
