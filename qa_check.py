#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
qa_check.py
用途：对一段刚录完的 XDF 文件做检查，按几条简单的必须满足的规则判断这次录制是不是合格。任意一条不达标，就当这次录制作废，立刻重录。该脚本目的只有一个：快速发现“录错文件、勾错流、窗口没覆盖、忘了按按钮”这类人为错误，省得到分析阶段才发现白忙活一场。

由于本流程比较繁琐，可能会不住细节、顺序容易错、流名容易混、目录容易点错。这个脚本帮你机械地检查三件事：录了多久、有没有标记、标记够不够。只要任何一条不过关，它就告诉你“这次无效”。接入 Verity/H10，这个脚本照样能用，对于高阶校验（比如波形质量、心率区间合理性）可以在后续再加更“细”的检查脚本。

规则死在脚本顶部，可以在脚本顶部“配置区”调阈值。脚本会打印：
- 文件路径
- 找到的每条流的名称、类型、样本数、时间跨度
- 标记列表与计数
- 结论：PASS / NOT PASS，并列出失败原因或告警。具体来说：

如果是 PASS，这次录制可用。
如果是 NOT PASS，输出会告诉你具体哪里不达标（比如没找到标记流、时长太短、标记太少）。直接按提示重录即可。
如果有 [WARN] 样本密度偏低，一般是手机发送频率和你设定的期望不一致（比如心跳本来不是 1 Hz），你可以：
要么把脚本顶部 EXPECTED_RATE_HZ 改成实际频率；
要么先不管这条告警（不影响 PASS/NOT PASS）。

"""

import sys

from collections import Counter

# “无命令行参数也能在 IDE 直接运行”加入可选的文件对话框支持
# 若系统无 Tkinter，可降级为从控制台输入路径
try:
    import os
    from tkinter import Tk, filedialog  # 可能在某些 Python 发行版中不可用
except Exception:
    Tk = None
    filedialog = None

def pick_file_dialog():
    """[新增] 弹出文件选择框选择 .xdf 文件；若 Tk 不可用则返回 None"""
    if Tk is None or filedialog is None:
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

# ── 配置区：按需要调整 ────────────────────────────────────────────────
MIN_DURATION_SEC    = 8      # 数据流最少录制秒数（防止“刚点开始就停止”的空文件）
MIN_MARKERS         = 2      # 最少标记条数（例如 baseline_start 与 stim_start）
EXPECTED_RATE_HZ    = 1.0    # 期望的数据流频率（当前心跳 1Hz）。若不想做密度校验，设为 0
DENSITY_FACTOR_MIN  = 0.7    # 密度阈值：样本数至少达到 0.7 * (时长 * 期望频率)，否则告警
# 名称识别优先级（可不改）：先按 type，再按 name 子串
DATA_NAME_HINTS     = ["udp"]        # 名称里含有这些子串的，优先当作“数据流”候选
MARKER_NAME_HINTS   = ["markers"]    # 名称里含有这些子串的，优先当作“标记流”候选
# ───────────────────────────────────────────────────────────────────

def _name(s): return s["info"]["name"][0] if s["info"]["name"] else ""
def _type(s): return s["info"]["type"][0] if s["info"]["type"] else ""

def _span_seconds(s):
    ts = s.get("time_stamps", None)
    if ts is None:
        return 0.0
    try:
        n = len(ts)
    except Exception:
        n = 0
    if n == 0:
        return 0.0
    return float(ts[n - 1] - ts[0])

def _pick_streams(streams):
    """
    返回 (data_stream, marker_stream)
    选择策略：
      - 标记流：优先 type=Markers；否则 name 包含 'markers'。
      - 数据流：优先 type!=Markers 且 name 包含 'udp'；否则在非标记流中选跨度最长的一条。
    """
    data = None
    mark = None

    # 先找标记流
    candidates_mark = []
    for s in streams:
        t = (_type(s) or "").lower()
        n = (_name(s) or "").lower()
        if t == "markers" or any(h in n for h in MARKER_NAME_HINTS):
            candidates_mark.append(s)
    if candidates_mark:
        # 如果有多条，取跨度最长的那条
        mark = max(candidates_mark, key=_span_seconds)

    # 再找数据流（排除已经当作标记的）
    candidates_data = []
    for s in streams:
        if s is mark:
            continue
        t = (_type(s) or "").lower()
        n = (_name(s) or "").lower()
        # 排除明显的标记类型
        if t == "markers":
            continue
        score = 0
        if any(h in n for h in DATA_NAME_HINTS):
            score += 10
        # 用跨度作为次要指标
        candidates_data.append((score, _span_seconds(s), s))
    if candidates_data:
        candidates_data.sort(key=lambda x: (x[0], x[1]), reverse=True)
        data = candidates_data[0][2]

    return data, mark

# 从一行 time_series 中提取标签，兼容 numpy.ndarray/bytes/列表/元组/字符串
def _extract_label(row):
    try:
        import numpy as np  # 只在需要时导入
        if isinstance(row, np.ndarray):
            row = row.tolist()
    except Exception:
        pass
    if isinstance(row, (list, tuple)):
        v = row[0] if row else ""
    else:
        v = row
    if isinstance(v, bytes):
        try:
            v = v.decode("utf-8", errors="ignore")
        except Exception:
            v = str(v)
    else:
        v = str(v)
    return v

def main():
    # 参数处理：支持三种方式获取路径
    # 1) 命令行参数；2) 文件对话框；3) 控制台输入
    if len(sys.argv) >= 2:
        path = sys.argv[1]
    else:
        path = pick_file_dialog()
        if not path:
            try:
                path = input("请输入 XDF 文件路径：").strip('"').strip("'").strip()
            except EOFError:
                path = ""

    # [新增] —— 基本有效性检查
    if not path:
        print("未提供有效的 .xdf 路径。")
        sys.exit(1)
    if 'os' in globals() and not os.path.isfile(path):
        print(f"文件不存在：{path}")
        sys.exit(1)


    try:
        import pyxdf
    except ImportError:
        print("缺少依赖：pyxdf。请先执行：pip install pyxdf")
        sys.exit(1)

    try:
        streams, hdr = pyxdf.load_xdf(path)
    except Exception as e:
        print(f"[ERROR] 无法读取 XDF：{e}")
        sys.exit(1)

    # 打印所有流的基本信息
    print(f"[FILE] {path}")
    if not streams:
        print("[FAIL] 文件中没有任何流")
        sys.exit(1)

    print("[STREAMS]")
    for s in streams:
        n = _name(s)
        t = _type(s)
        cnt = len(s["time_series"])
        sp = _span_seconds(s)
        print(f"  - name='{n}' | type='{t or ''}' | samples={cnt} | span={sp:.2f}s")

    data, mark = _pick_streams(streams)

    all_pass = True

    # 规则 1：必须同时存在数据流与标记流
    if data is None:
        print("[FAIL] 未找到“数据流”（例如名字里含 udp 的那条）")
        all_pass = False
    if mark is None:
        print("[FAIL] 未找到“标记流”（type=Markers 或名字里含 markers）")
        all_pass = False

    # 若缺流，直接给出结论
    if not all_pass:
        print("[RESULT] NOT PASS")
        sys.exit(1)

    # 统计关键指标
    n_data = len(data["time_series"])
    n_mark = len(mark["time_series"])
    dur_data = _span_seconds(data)
    dur_mark = _span_seconds(mark)

    # 打印标记详情
    labels = [_extract_label(row) for row in mark["time_series"]]
    print(f"[DATA ] samples={n_data} | span={dur_data:.2f}s | name='{_name(data)}'")
    print(f"[MARK ] samples={n_mark} | span={dur_mark:.2f}s | name='{_name(mark)}'")
    print(f"[LABEL] {labels}")
    print(f"[COUNT] {Counter(labels)}")

    # 规则 2：数据流最短时长
    if dur_data < MIN_DURATION_SEC:
        print(f"[FAIL] 数据时长 {dur_data:.2f}s < 最小要求 {MIN_DURATION_SEC}s")
        all_pass = False

    # 规则 3：最少标记数
    if n_mark < MIN_MARKERS:
        print(f"[FAIL] 标记条数 {n_mark} < 最小要求 {MIN_MARKERS}")
        all_pass = False

    # 规则 4：样本密度（可选，默认只告警）
    if EXPECTED_RATE_HZ > 0 and dur_data > 0:
        expected_min = int(dur_data * EXPECTED_RATE_HZ * DENSITY_FACTOR_MIN)
        if n_data < expected_min:
            print(f"[WARN] 样本密度偏低：实际 {n_data}，阈值 {expected_min}（期望频率 {EXPECTED_RATE_HZ}Hz）")
            # 这里只做告警，不拉红
            # 如需严格，改成 all_pass = False

    print("[RESULT] PASS" if all_pass else "[RESULT] NOT PASS")
    sys.exit(0 if all_pass else 1)

if __name__ == "__main__":
    main()
