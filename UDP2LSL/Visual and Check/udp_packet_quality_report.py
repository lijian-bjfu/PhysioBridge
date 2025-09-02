#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
udp_packet_quality_report.py
读取 bridge_hub.py 周期写入的 *.metrics.jsonl，生成一页式中文 Markdown 报告，
并输出 3 张用于快速诊断的图：
  1) rtt.png         —— ping-pong 往返时延（RTT）随时间
  2) ecg_loss.png    —— 新增丢包(包) 与 瞬时丢包率(%) 随时间
  3) ecg_gap_rate.png—— 60秒样本差 与 速率(Hz) 随时间

用法：
  python udp_packet_quality_report.py
  # 或手动指定
  python udp_packet_quality_report.py --metrics UDP2LSL/logs/S20250901-120000.metrics.jsonl --out UDP2LSL/logs/S20250901-120000_udp_quality.md
"""
import argparse, json, statistics, math
from pathlib import Path

# 尝试导入绘图，不强制要求
try:
    import matplotlib.pyplot as plt
    _PLT_OK = True
except Exception:
    _PLT_OK = False

EVENT_TYPES = {"rr", "hr", "ppi"}

# 评估阈值（尽量少、够用）
LOSS_FIXED_GREEN = 0.005   # 定频流丢包 <0.5% 绿
LOSS_FIXED_YELLOW= 0.02    # 0.5–2% 黄，>2% 红
LOSS_EVT_GREEN   = 0.01    # 事件流丢包 <1% 绿
LOSS_EVT_YELLOW  = 0.03    # 1–3% 黄，>3% 红
JITTER_P95_GREEN = 30.0    # 定频：p95 抖动 <30ms 绿
JITTER_P95_YELLOW= 80.0    # 30–80ms 黄，>80% 红
GAP60S_WARN_FRAC = 0.01    # 60s 理论样本数的 1% 以上给 WARN
RTT_SPIKE_MS     = 80.0    # RTT 尖峰阈值，用于标注问题时段

def classify_fixed(loss_rate, jitter_p95, gap60s_max, fs_guess):
    if loss_rate < LOSS_FIXED_GREEN:
        loss_grade = "绿"
    elif loss_rate < LOSS_FIXED_YELLOW:
        loss_grade = "黄"
    else:
        loss_grade = "红"
    if jitter_p95 < JITTER_P95_GREEN:
        jit_grade = "绿"
    elif jitter_p95 < JITTER_P95_YELLOW:
        jit_grade = "黄"
    else:
        jit_grade = "红"
    gap_warn = (gap60s_max > (fs_guess * 60.0 * GAP60S_WARN_FRAC)) if fs_guess else (gap60s_max > 0)
    return loss_grade, jit_grade, gap_warn

def classify_event(loss_rate):
    if loss_rate < LOSS_EVT_GREEN:
        return "绿"
    elif loss_rate < LOSS_EVT_YELLOW:
        return "黄"
    else:
        return "红"

def p95(vals):
    if not vals: return 0.0
    vals = sorted(vals)
    k = int(round(0.95 * (len(vals)-1)))
    return float(vals[k])

def parse_lines(path):
    snaps = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                snaps.append(json.loads(line))
            except Exception:
                continue
    return snaps

def grade_rank(g):
    return {"绿":0,"黄":1,"红":2}.get(g, 0)

def stability_word(jit_p95):
    if jit_p95 < JITTER_P95_GREEN: return "稳定"
    if jit_p95 < JITTER_P95_YELLOW: return "一般"
    return "不稳定"

def choose_timesync_dev(snaps):
    """选择出现次数最多的 timesync 设备"""
    count = {}
    for s in snaps:
        tsync = s.get("timesync", {})
        for dev in tsync.keys():
            count[dev] = count.get(dev, 0) + 1
    if not count: return None
    return max(count.items(), key=lambda kv: kv[1])[0]

def extract_series(snaps, first_ts, key):
    """提取某条业务流的时间序列"""
    t, loss_rate, miss_cum, gap60s, rate_hz = [], [], [], [], []
    for s in snaps:
        snap = s.get("snapshot", {})
        v = snap.get(key)
        if not v: 
            continue
        t.append(s["ts"] - first_ts)
        loss_rate.append(float(v["pkts"]["loss_rate"])*100.0)
        miss_cum.append(int(v["pkts"]["miss"]))
        typ = (key.split("|",1)+[""])[1]
        if typ not in EVENT_TYPES:
            gap60s.append(float(v["samples_60s"]["gap"]))
            rate_hz.append(float(v["ia_10s"]["rate_hz"]))
    # 计算每周期“新增丢包包数”
    miss_new = []
    for i, m in enumerate(miss_cum):
        if i == 0: miss_new.append(0)
        else: miss_new.append(max(0, m - miss_cum[i-1]))
    return t, loss_rate, miss_new, gap60s, rate_hz

def make_plots(mpath: Path, snaps, per_stream):
    """生成三张图到与报告同目录；返回相对文件名列表"""
    out_dir = mpath.parent
    first_ts = snaps[0]["ts"]
    images = []

    # ===== 1) RTT over time =====
    dev = choose_timesync_dev(snaps)
    if dev and _PLT_OK:
        t_rtt, v_rtt = [], []
        for s in snaps:
            tsync = s.get("timesync", {})
            d = tsync.get(dev)
            if not d:
                continue
            t_rtt.append(s["ts"] - first_ts)
            v_rtt.append(float(d.get("rtt_ms", 0.0)))

        if t_rtt:
            plt.figure()
            # plt.plot(t_rtt, v_rtt, label=f"RTT (ms) [{dev}]")
            plt.plot(t_rtt, v_rtt, label=f"RTT (ms) [{dev}]", color="C0", linewidth=1.8)
#            阈值：虚线 C2
            # plt.axhline(RTT_SPIKE_MS, linestyle="--", label=f"Threshold {int(RTT_SPIKE_MS)} ms")
            plt.axhline(RTT_SPIKE_MS, linestyle="--", label=f"Threshold {int(RTT_SPIKE_MS)} ms", color="C2", linewidth=1.2)
            # spike markers
            spikes_t = [t for t, r in zip(t_rtt, v_rtt) if r > RTT_SPIKE_MS]
            spikes_v = [r for r in v_rtt if r > RTT_SPIKE_MS]
            if spikes_t:
                plt.scatter(spikes_t, spikes_v, marker="o", label="RTT spikes (> threshold)",
                color="C3", s=28, edgecolors="none")
            plt.xlabel("Time (s)")
            plt.ylabel("RTT (ms)")
            plt.title("Ping-Pong RTT over time")
            plt.legend()
            plt.tight_layout()
            p = out_dir / (mpath.stem.replace(".metrics", "") + "_rtt.png")
            plt.savefig(p, dpi=150)
            plt.close()
            images.append(p.name)

    # ===== 2) 选一条连续波形作参考（ECG>PPG>ACC） =====
    prefer = None
    keys = sorted(per_stream.keys())
    for cand in ["|ecg", "|ppg", "|acc"]:
        for k in keys:
            if cand in k:
                prefer = k; break
        if prefer: break
    if not prefer:
        for k in keys:
            typ = (k.split("|",1)+[""])[1]
            if typ not in EVENT_TYPES:
                prefer = k; break

    if prefer and _PLT_OK:
        t, loss_rate, miss_new, gap60s, rate_hz = extract_series(snaps, first_ts, prefer)

        # 2a) Loss dynamics：双纵轴（左=新增丢包包数，右=瞬时丢包率%）
        if t and (any(miss_new) or any(loss_rate)):
            fig, ax1 = plt.subplots()
            if any(miss_new):
                ax1.plot(t, miss_new, label="New missing packets (per interval)",
                        color="C0", linestyle="-", marker="o", markersize=3, linewidth=1.6)
            ax1.set_ylabel("Missing (pkts/interval)")
            ax1.set_xlabel("Time (s)")
            ax2 = ax1.twinx()
            if any(loss_rate):
                ax2.plot(t, loss_rate, label="Instant loss rate (%)",
                        color="C3", linestyle="--", linewidth=1.6)
                ax2.set_ylabel("Loss rate (%)")
            # 合并图例
            h1, l1 = ax1.get_legend_handles_labels()
            h2, l2 = ax2.get_legend_handles_labels()
            if h1 or h2:
                ax1.legend(h1+h2, l1+l2, loc="upper left")
            plt.title(f"Loss dynamics [{prefer}]")
            fig.tight_layout()
            p = out_dir / (mpath.stem.replace(".metrics","") + "_ecg_loss.png")
            fig.savefig(p, dpi=150)
            plt.close(fig)
            images.append(p.name)

        # 2b) Gap & Rate：双纵轴（左=60s 样本差，右=到达速率Hz）
        if t and (any(gap60s) or any(rate_hz)):
            fig, ax1 = plt.subplots()
            if any(gap60s):
                ax1.plot(t, gap60s, label="60s sample gap (pts)",
                        color="C0", linestyle="-", linewidth=1.8)
                ax1.set_ylabel("60s sample gap (pts)")
            ax1.set_xlabel("Time (s)")
            ax2 = ax1.twinx()
            if any(rate_hz):
                ax2.plot(t, rate_hz, label="Rate (Hz)",
                        color="C1", linestyle="-.", linewidth=1.6)
                ax2.set_ylabel("Rate (Hz)")
            h1, l1 = ax1.get_legend_handles_labels()
            h2, l2 = ax2.get_legend_handles_labels()
            if h1 or h2:
                ax1.legend(h1+h2, l1+l2, loc="upper left")
            plt.title(f"Gap & rate [{prefer}]")
            fig.tight_layout()
            p = out_dir / (mpath.stem.replace(".metrics","") + "_ecg_gap_rate.png")
            fig.savefig(p, dpi=150)
            plt.close(fig)
            images.append(p.name)

    return images


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics", required=False, help="*.metrics.jsonl 文件路径（可不填）")
    ap.add_argument("--logdir", required=False, help="日志目录，缺省为脚本上级目录的 logs/")
    ap.add_argument("--out", help="输出 Markdown 路径")
    args = ap.parse_args()

    # 选择输入文件
    if args.metrics:
        mpath = Path(args.metrics)
    else:
        default_logdir = Path(args.logdir) if args.logdir else Path(__file__).resolve().parents[1] / "logs"
        cand = sorted(default_logdir.glob("*.metrics.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not cand:
            print(f"在 {default_logdir} 没找到 *.metrics.jsonl；可以用 --logdir 指定目录，或用 --metrics 指定文件。")
            return
        mpath = cand[0]
        print(f"未提供 --metrics，使用最新文件：{mpath}")

    out = Path(args.out) if args.out else mpath.with_name(mpath.stem.replace(".metrics", "") + "_udp_quality.md")

    snaps = parse_lines(mpath)
    if not snaps:
        print("没有可用的 metrics 快照。")
        return

    first_ts = snaps[0]["ts"]
    last_ts  = snaps[-1]["ts"]
    duration = last_ts - first_ts

    # 聚合
    streams = {}
    for s in snaps:
        snap = s.get("snapshot", {})
        for key, v in snap.items():
            rec = streams.setdefault(key, {
                "pkts_recv": [], "pkts_miss": [],
                "loss_rate": [], "rate_hz": [], "jitter_ms": [],
                "gap60s": [], "fs_guess": 0.0
            })
            pk = v["pkts"]
            rec["pkts_recv"].append(pk["recv"])
            rec["pkts_miss"].append(pk["miss"])
            rec["loss_rate"].append(v["pkts"]["loss_rate"])
            rec["rate_hz"].append(v["ia_10s"]["rate_hz"])
            typ = (key.split("|",1)+[""])[1]
            if typ not in EVENT_TYPES:
                rec["jitter_ms"].append(v["ia_10s"]["jitter_ms"])
                rec["gap60s"].append(v["samples_60s"]["gap"])

    # 先生成每路的结论，顺便算全局 TL;DR
    per_stream = {}
    worst_grade = "绿"
    for key, rec in streams.items():
        dev, typ = (key.split("|",1)+[""])[:2]
        last_recv = rec["pkts_recv"][-1]
        last_miss = rec["pkts_miss"][-1]
        last_loss = rec["loss_rate"][-1] if rec["loss_rate"] else 0.0
        rate_med  = statistics.median(rec["rate_hz"]) if rec["rate_hz"] else 0.0

        if typ in EVENT_TYPES:
            grade = classify_event(last_loss)
            bpm = round(rate_med * 60) if rate_med else 0
            impact = {
                "绿": "整体稳定，可用于分析。",
                "黄": "有少量漏记，建议结合 ECG 重建 RR 或复核关键片段。",
                "红": "丢包较高，建议重跑或剔除受影响片段；必要时用 ECG 重建 RR 兜底。"
            }[grade]
            per_stream[key] = {
                "dev":dev, "typ":typ, "recv":last_recv, "miss":last_miss,
                "loss":last_loss, "rate_med":rate_med, "bpm":bpm,
                "grade":grade, "impact":impact
            }
        else:
            jit_p95 = p95(rec["jitter_ms"]) if rec["jitter_ms"] else 0.0
            gap_max = max(rec["gap60s"]) if rec["gap60s"] else 0.0
            g_loss, g_jit, gap_warn = classify_fixed(last_loss, jit_p95, gap_max, 0.0)
            grade = max((g_loss, g_jit), key=grade_rank)
            impact = {
                "绿": "整体稳定，可用于分析。",
                "黄": "有轻微丢包/波动，建议留意关键窗口；形态学分析请谨慎。",
                "红": "连续波形缺段或波动明显，建议靠近路由器、使用 5GHz、或减小每包样本数后重跑。"
            }[grade]
            per_stream[key] = {
                "dev":dev, "typ":typ, "recv":last_recv, "miss":last_miss,
                "loss":last_loss, "rate_med":rate_med, "bpm":0,
                "grade":grade, "impact":impact,
                "jit_p95":jit_p95, "stability":stability_word(jit_p95),
                "gap_max":gap_max
            }

        if grade_rank(grade) > grade_rank(worst_grade):
            worst_grade = grade

    # TL;DR
    if worst_grade == "红":
        tldr = "不通过。存在红色警告，建议靠近路由器、使用 5GHz、并将每包样本数下调 20–30% 后重跑。"
    elif worst_grade == "黄":
        tldr = "谨慎使用。总体可用，但存在轻微风险；请保留原始文件并复核关键窗口。"
    else:
        tldr = "通过。本次 UDP 传输质量满足快速预测试的基本需求。"

    # 先生成图
    images = make_plots(mpath, snaps, per_stream)

    # 计算 timesync 统计（用于“网络稳定性”摘要）
    rtt_med = rtt_p95 = None
    spike_cnt = 0
    dev_tsync = choose_timesync_dev(snaps)
    if dev_tsync:
        rtts = []
        for s in snaps:
            d = s.get("timesync", {}).get(dev_tsync)
            if d and isinstance(d.get("rtt_ms"), (int,float)):
                rtts.append(float(d["rtt_ms"]))
        if rtts:
            rtt_med = statistics.median(rtts)
            rtt_p95 = p95(rtts)
            spike_cnt = sum(1 for x in rtts if x > RTT_SPIKE_MS)

    # 生成报告（Markdown）
    lines = []
    lines.append(f"# UDP 传输质量简报\n")
    lines.append(f"**TL;DR：{tldr}**\n")
    lines.append(f"- 会话时长：约 {int(duration)} 秒")
    lines.append(f"- 数据来源：{mpath.name}")
    lines.append("")
    lines.append("## 怎么看这份简报（给非工程专业的研究者）")
    lines.append("- **丢包率**：数字越小越好。连续波形（ECG/ACC/PPG）丢包会造成波形缺段；事件（RR/HR/ppi）丢包会漏掉个别事件。")
    lines.append("- **到达时间稳定性**：只对连续波形有意义。显示为“稳定/一般/不稳定”，括号里给出技术指标 p95。")
    lines.append("- **样本差（60秒）**：理论上 60 秒应收到多少样本，实际到了多少；接近 0 最好。")
    lines.append("- **颜色含义**：绿=好（放心用），黄=一般（留意），红=差（建议重跑或剔除受影响片段）。\n")

    lines.append("## 各数据流情况")
    for key in sorted(per_stream.keys()):
        ps = per_stream[key]
        dev, typ = ps["dev"], ps["typ"]
        lines.append(f"### {dev} | {typ.upper()}")
        lines.append(f"- 包统计：pkts={ps['recv']}  miss={ps['miss']}  丢包率={ps['loss']*100:.2f}%")
        if typ in EVENT_TYPES:
            bpm = ps["bpm"]
            lines.append(f"- 事件频率：约 {bpm} bpm" if bpm else "- 事件频率：—")
            lines.append(f"- 评价：**{ps['grade']}**")
            lines.append(f"- 影响与建议：{ps['impact']}")
        else:
            jit_p95 = ps["jit_p95"]
            lines.append(f"- 到达时间稳定性：{ps['stability']}（p95≈{jit_p95:.1f} ms）")
            lines.append(f"- 60秒样本差：最大 {ps['gap_max']:.0f} 点（0 最佳）")
            lines.append(f"- 评价：**{ps['grade']}**")
            lines.append(f"- 影响与建议：{ps['impact']}")
        lines.append("")

    # 新增：网络稳定性图表
    lines.append("## 网络稳定性图表")
    if rtt_med is not None:
        lines.append(f"- RTT 中位数 ≈ {rtt_med:.1f} ms，p95 ≈ {rtt_p95:.1f} ms，尖峰(>{int(RTT_SPIKE_MS)}ms) 次数：{spike_cnt}")
    else:
        lines.append("- 未采集到 timesync 数据。")

    if images:
        lines.append("")
        for img in images:
            lines.append(f"![{img}]({img})")

    # 图表如何阅读（英文图注对应中文解释）
    lines.append("\n### How to read these figures")
    lines.append("- **RTT over time**：折线是往返时延（毫秒），虚线是阈值（80 ms），散点是超过阈值的尖峰。尖峰出现的秒数就是“网络打喷嚏”的时段。")
    lines.append("- **Loss dynamics**：左轴是每个汇总周期的“新增丢包包数”，右轴是“瞬时丢包率(%)”。若左轴出现连续非零台阶，说明有成段缺口。")
    lines.append("- **Gap & rate**：左轴是 60s sample gap（应到样本与实到样本之差），右轴是到达速率 Rate(Hz)。gap 抬高同时速率下降，基本就是链路拥塞或系统停顿。")


    # 总体结论
    if worst_grade == "红":
        lines.append("\n## 总体结论：**不通过**")
    elif worst_grade == "黄":
        lines.append("\n## 总体结论：**谨慎使用**")
    else:
        lines.append("\n## 总体结论：**通过**")

    Path(out).write_text("\n".join(lines), encoding="utf-8")
    print(f"已生成报告：{out}")
    if not _PLT_OK:
        print("提示：未安装 matplotlib，无法绘图。可通过 `pip install matplotlib` 安装后重试。")

if __name__ == "__main__":
    main()
