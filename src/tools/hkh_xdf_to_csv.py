import os
import csv
from pathlib import Path
import pyxdf
from tkinter import Tk, filedialog
from typing import List, Dict, Any, Optional, Tuple

import sys
# 获取当前工作目录
project_root = os.getcwd()
# 确保项目根目录已添加到 sys.path
if project_root not in sys.path:
    sys.path.insert(0, project_root)
from paths import RECORDER_DATA_DIR


# 确保输出目录存在
def ensure_out(out_dir: Path):
    if not out_dir.exists():
        out_dir.mkdir(parents=True, exist_ok=True)

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

# 获取 Lab Recorder 数据路径
def pick_file_dialog() -> Optional[Path]:
    if Tk is None or filedialog is None: return None
    root = Tk(); root.withdraw(); root.update()
    initial_dir = str(RECORDER_DATA_DIR)
    p = filedialog.askopenfilename(title="选择 HKH XDF 文件",
                                    initialdir=initial_dir,
                                    filetypes=[("XDF files","*.xdf"),("All files","*.*")])
    root.destroy(); return Path(p) if p else None

def iter_streams_by_type(streams, typ: str):
    """返回所有 stype 命中的流（全量），忽略大小写"""
    t = typ.lower()
    for s in streams:
        st = ((s.get("info",{}).get("type") or [""])[0] or "").lower()
        if st == t:
            yield s

def parse_name_parts(name: str) -> Tuple[str, str, str]:
    """
    约定名形如 PB_<KIND>_<DEVICE>，例如 PB_ACC_H10 / PB_PPG_Verity
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
    header = ["time_lsl", "ad"]  # 如果你希望与文档描述一致，可改成 ["time_lsl","BreathingValue"]
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


# === 报告收集与输出 ===
EXTRA_DOC: Dict[str, List[str]] = {
    "Respiration": [  # 添加呼吸数据的文档说明
        "呼吸数据来自 HKH-11C（呼吸带），单位通常为 arbitrary_units 或 raw。",
        "频率约为50Hz, 数据点间隔约为20毫秒。"
    ]
}

def _col_desc_map(kind: str, header: List[str]) -> List[str]:
    descs = []
    for col in header:
        c = col.lower()
        if c == "time_lsl":
            descs.append("LSL 时间戳（秒，local_clock 单调时钟）")
        elif kind == "Respiration":
            descs.append("呼吸强度值（arbitrary_units 或 raw）")
        else:
            descs.append("未知列")
    return descs

def _add_report(report: List[Dict[str, Any]], kind: str, out_path: Path, header: List[str], rows: int):
    """
    添加报告数据，记录文件的导出信息。
    """
    report.append({
        'kind': kind,
        'file': str(out_path),
        'rows': rows,
        "cols": len(header),
        'header': header,
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

# === 主流程 ===========================================================
def main():
    # 1) 获取路径
    import sys
    if len(sys.argv) >= 2:
        xdf_path = Path(sys.argv[1]).expanduser()
    else:
        # 根据用户在系统窗口选择文件
        xdf_path = pick_file_dialog()  # 选择Polar数据路径
        if xdf_path is None:
            try:
                raw = input("请输入 HKH XDF 文件路径：").strip().strip('"').strip("'")
                xdf_path = Path(raw) if raw else None
            except EOFError:
                xdf_path = None
        if xdf_path is None or not xdf_path.exists():
            print("[ERROR] 未提供有效 .xdf"); return

    out_root = RECORDER_DATA_DIR
    out_dir = out_root /  "HKH" / xdf_path.stem
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

    # 3) 数值型导出（逐类型 * 多设备*）
    typed = {
        "Respiration": list(iter_streams_by_type(streams, "Respiration")),
    }

    # 按类型批量导出
    for st in typed["Respiration"]:
        export_hkh(st, stem, out_dir, report)

    # 4) 生成报告
    if report:
        _emit_report(out_dir, stem, report)
    else:
        print("[WARN] 没有生成任何 CSV，报告跳过。")

# 启动主函数
if __name__ == "__main__":
    main()
