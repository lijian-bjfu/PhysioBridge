#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys, os
from pathlib import Path
from collections import Counter

try:
    # 可选：用于弹出文件选择框；若缺失会自动回退
    from tkinter import Tk, filedialog  # type: ignore
except Exception:
    Tk = None

from pyxdf import load_xdf

def pick_file_dialog():
    if Tk is None:
        return None
    root = Tk()
    root.withdraw()
    root.update()
    path = filedialog.askopenfilename(
        title="Select XDF file",
        filetypes=[("XDF files", "*.xdf"), ("All files", "*.*")]
    )
    root.destroy()
    return path or None

def resolve_path():
    # 1) 命令行参数
    if len(sys.argv) > 1:
        return sys.argv[1]
    # 2) 环境变量
    env = os.getenv("XDF_PATH")
    if env:
        return env
    # 3) 图形文件对话框
    return pick_file_dialog()

# 寻找“标记”流：优先按 type=Markers，其次按 name 含 markers
def is_marker_stream(s):
    name = s["info"]["name"][0] if s["info"]["name"] else ""
    typ  = s["info"]["type"][0] if s["info"]["type"] else ""
    return (typ and typ.lower() == "markers") or ("markers" in name.lower())

def main():
    path = resolve_path()
    if not path:
        print("请这样使用：\n"
              "  A) 终端：python check_xdf.py /path/to/file.xdf\n"
              "  B) 终端：XDF_PATH=/path/to/file.xdf python check_xdf.py\n"
              "  C) 直接运行：弹出文件对话框（若 Tkinter 不可用，则请用 A 或 B）")
        sys.exit(2)

    path = str(Path(path).expanduser())
    streams, hdr = load_xdf(path)

    print(f"File: {path}")
    for s in streams:
        name = s["info"]["name"][0]
        typ  = s["info"]["type"][0] if s["info"]["type"] else ""
        n    = len(s["time_series"])
        if n:
            t0 = s["time_stamps"][0]
            t1 = s["time_stamps"][-1]
            dur = t1 - t0
            print(f"{name:20s} | type={typ:10s} | samples={n:6d} | span={dur:7.2f}s")
        else:
            print(f"{name:20s} | type={typ:10s} | samples={n:6d}")

    # 打印 markers 内容（若存在）
    marker_streams = [s for s in streams if is_marker_stream(s)]
    if marker_streams:
        s = marker_streams[0]
        labels = [row[0] for row in s["time_series"]]
        # 打印全部标签与出现次数
        print("Markers:", labels)
        from collections import Counter
        print("Marker counts:", Counter(labels))
    else:
        print("No marker stream found by type/name.")

if __name__ == "__main__":
    main()
