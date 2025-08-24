#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# ── 配置区：只改这里 ────────────────────────────────────────────────
from pathlib import Path
from zeroconf import Zeroconf, ServiceInfo, IPVersion
import time
import socket
import json
import uuid
from typing import List, Tuple
from pylsl import StreamInfo, StreamOutlet, local_clock

CONFIG = {
    # UDP 监听地址与端口（iPhone/发包端要把目标指向本机IP:PORT）
    "HOST": "0.0.0.0",
    "PORT": 9001,
    # 会话ID：默认用时间戳。若想手工固定，改成 "S20250820-01" 这类字符串
    "SESSION": time.strftime("S%Y%m%d-%H%M%S"),
    # LSL 流名后缀：开发期建议用 "_TEST"，稳定后可改成空字符串 ""
    "NAME_SUFFIX": "_TEST",
    # 旁路日志目录（逐条 UDP 入站会落到这里的 .jsonl）
    "LOGDIR": str(Path.home() / "lsl_logs"),
    # 控制台统计摘要的间隔秒数
    "SUMMARY_EVERY": 5,
}
# ────────────────────────────────────────────────────────────────

# 该函数的目的是桥接器在局域网里主动“广播自己的存在”，移动端通过 Bonjour/mDNS 发现它，然后自动更新 udpHost/udpPort
# 优先挑选 RFC1918 私网地址；次选主机名解析出的私网地址；最后退回 127.0.0.1
_PRIVATE_CANDIDATE_PREFIXES = [
    ("192.168.", 0),  # 最高优先级：家庭路由常用
    ("10.",       1),
    *[(f"172.{i}.", 2) for i in range(16, 32)],  # 172.16/12
]

def _is_private_ipv4(ip: str) -> bool:
    if ip.startswith("127."):  # 回环不要
        return False
    return any(ip.startswith(p) for p, _ in _PRIVATE_CANDIDATE_PREFIXES)

def _collect_private_ipv4_candidates() -> List[Tuple[int, str]]:
    """收集本机所有可能的私网 IPv4，并按优先级打分"""
    cand = set()

    # 1) 连外探针（选路后的本机地址）
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        cand.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass

    # 2) 主机名解析到的 IPv4
    try:
        infos = socket.getaddrinfo(socket.gethostname(), None, family=socket.AF_INET)
        for item in infos:
            cand.add(item[4][0])
    except Exception:
        pass

    # 3) 去掉非私网与回环
    priv = [ip for ip in cand if _is_private_ipv4(ip)]

    # 4) 计算优先级：192.168.* 优先于 10.* 再优于 172.16–31.*
    scored: List[Tuple[int, str]] = []
    for ip in priv:
        score = 3  # 默认最低
        for prefix, rank in _PRIVATE_CANDIDATE_PREFIXES:
            if ip.startswith(prefix):
                score = rank
                break
        scored.append((score, ip))
    # 分数小者优先；同分随意
    scored.sort(key=lambda t: t[0])
    return scored

def _lan_ipv4() -> str:
    """返回“最合适的”私网 IPv4。没有则回 127.0.0.1"""
    scored = _collect_private_ipv4_candidates()
    if scored:
        return scored[0][1]
    return "127.0.0.1"


def _name(base: str) -> str:
    suf = CONFIG["NAME_SUFFIX"] or ""
    return f"{base}{suf}"


def _make_outlet(name: str, stype: str, source_id: str, channel_format: str = "string"):
    info = StreamInfo(name, stype, 1, 0.0, channel_format, source_id)
    desc = info.desc()
    desc.append_child_value("impl", "udp_to_lsl_v2")
    desc.append_child_value("session", CONFIG["SESSION"])
    desc.append_child_value("created_at", time.strftime("%Y-%m-%dT%H:%M:%S"))
    return info, StreamOutlet(info, chunk_size=0, max_buffered=360)


def main():
    # 准备日志
    Path(CONFIG["LOGDIR"]).mkdir(parents=True, exist_ok=True)
    log_path = Path(CONFIG["LOGDIR"]) / f"{CONFIG['SESSION']}.jsonl"
    logf = open(log_path, "a", buffering=1, encoding="utf-8")

    # 绑定 UDP
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((CONFIG["HOST"], CONFIG["PORT"]))
    except OSError as e:
        print(f"[FATAL] UDP {CONFIG['HOST']}:{CONFIG['PORT']} bind failed: {e}")
        return
    sock.setblocking(True)

    # 唯一 source_id
    sid_data = f"pb_udp_{CONFIG['SESSION']}_{uuid.uuid4().hex[:8]}"
    sid_mark = f"pb_markers_{CONFIG['SESSION']}_{uuid.uuid4().hex[:8]}"

    # 两路 LSL 流
    name_data = _name("PB_UDP")
    name_mark = _name("PB_MARKERS")
    info_data, outlet_data = _make_outlet(name_data, "udp_text", sid_data)
    info_mark, outlet_mark = _make_outlet(name_mark, "Markers", sid_mark)

    print(f"[udp_to_lsl] session={CONFIG['SESSION']}")
    print(f"[udp_to_lsl] listening on {CONFIG['HOST']}:{CONFIG['PORT']}")
    print(
        f"[udp_to_lsl] LSL outlets: {name_data} (sid={sid_data}), {name_mark} (sid={sid_mark})"
    )
    print(f"[udp_to_lsl] log file: {log_path}")

    # === Bonjour / Zeroconf 注册（发布桌面端服务） ===
    zc = None
    svc = None
    try:
        if Zeroconf is not None and ServiceInfo is not None:
            host_ip = _lan_ipv4()
            zc = Zeroconf(interfaces=[host_ip], ip_version=IPVersion.V4Only)

            svc = ServiceInfo(
                type_="_pbudp._udp.local.",
                name=f"udp_to_lsl on {socket.gethostname()}._pbudp._udp.local.",
                addresses=[socket.inet_aton(host_ip)],  # 显式广播私网 IPv4
                port=CONFIG["PORT"],
                properties={"session": CONFIG["SESSION"], "impl": "udp_to_lsl"},
            )
            zc.register_service(svc)
            print(f"[udp_to_lsl] bonjour: _pbudp._udp at {host_ip}:{CONFIG['PORT']}")
        else:
            print("[udp_to_lsl] bonjour: zeroconf not installed -> skip")
    except Exception as e:
        print(f"[udp_to_lsl] bonjour: register failed -> {e}")

    count_data = 0
    count_mark = 0
    t0 = time.time()

    try:
        while True:
            data, addr = sock.recvfrom(65535)
            ts = local_clock()

            try:
                text = data.decode("utf-8", errors="ignore").strip()
            except Exception:
                text = f"<{len(data)} bytes>"

            # 旁路日志：每条 UDP 入站都写盘
            logf.write(
                json.dumps({"ts_host": time.time(), "remote": addr, "raw": text}) + "\n"
            )

            # 路由：marker 单独走标记流，其它都进数据流
            routed = False
            try:
                obj = json.loads(text)
                if isinstance(obj, dict) and obj.get("type") == "marker":
                    raw_label = obj.get("label", "")
                    label = (
                        raw_label
                        if isinstance(raw_label, str) and raw_label.strip()
                        else "unknown"
                    )
                    outlet_mark.push_sample([label], timestamp=ts)
                    count_mark += 1
                    print(f"[MARK #{count_mark}] {addr} -> {label}")
                    routed = True
            except Exception:
                pass

            if not routed:
                outlet_data.push_sample([text], timestamp=ts)
                count_data += 1
                print(f"[DATA #{count_data}] {addr} -> {text}")

            # 周期性摘要
            now = time.time()
            if now - t0 >= CONFIG["SUMMARY_EVERY"]:
                print(
                    f"[SUMMARY] data={count_data}, markers={count_mark}, elapsed={int(now - t0)}s"
                )
                t0 = now
    finally:
        # === Bonjour / Zeroconf 注销 ===
        try:
            if zc is not None and svc is not None:
                zc.unregister_service(svc)
                zc.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
