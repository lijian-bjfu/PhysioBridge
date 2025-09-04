#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from zeroconf import Zeroconf, ServiceInfo, IPVersion
import time
import socket
from typing import List, Tuple

# ── 配置区：确保这里的配置与主脚本一致 ────────────────────────────────
CONFIG = {
    # 需要广播的 UDP 端口
    "PORT": 9001,
    # 会话ID：默认用时间戳。若与主脚本手工固定，这里也要保持一致
    "SESSION": time.strftime("S%Y%m%d-%H%M%S"),
}
# ──────────────────────────────────────────────────────────────────

# === 以下是用于查找本机局域网IP的辅助函数 ===

_PRIVATE_CANDIDATE_PREFIXES = [
    ("192.168.", 0),  # 最高优先级：家庭路由常用
    ("10.",       1),
    *[(f"172.{i}.", 2) for i in range(16, 32)],  # 172.16/12
]

def _is_private_ipv4(ip: str) -> bool:
    """检查是否为私网IPv4地址（不包括回环地址）"""
    if ip.startswith("127."):
        return False
    return any(ip.startswith(p) for p, _ in _PRIVATE_CANDIDATE_PREFIXES)

def _collect_private_ipv4_candidates() -> List[Tuple[int, str]]:
    """收集本机所有可能的私网 IPv4，并按优先级打分"""
    cand = set()

    # 1) 通过连接外网尝试获取本机地址
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        cand.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass

    # 2) 通过主机名解析获取所有IPv4地址
    try:
        infos = socket.getaddrinfo(socket.gethostname(), None, family=socket.AF_INET)
        for item in infos:
            cand.add(item[4][0])
    except Exception:
        pass

    # 3) 过滤出私网地址
    priv = [ip for ip in cand if _is_private_ipv4(ip)]

    # 4) 计算优先级分数
    scored: List[Tuple[int, str]] = []
    for ip in priv:
        score = 3  # 默认最低分
        for prefix, rank in _PRIVATE_CANDIDATE_PREFIXES:
            if ip.startswith(prefix):
                score = rank
                break
        scored.append((score, ip))
    
    scored.sort(key=lambda t: t[0])
    return scored

def _lan_ipv4() -> str:
    """返回“最合适的”私网 IPv4。如果没有，则返回 127.0.0.1"""
    scored = _collect_private_ipv4_candidates()
    if scored:
        return scored[0][1]
    return "127.0.0.1"


def main():
    """主函数，负责注册并持续广播网络服务"""
    print("[broadcaster] starting service discovery...")
    
    host_ip = _lan_ipv4()
    if host_ip == "127.0.0.1":
        print("[broadcaster] WARNING: Could not find a private IP address. Broadcasting on localhost.")

    zc = Zeroconf(interfaces=[host_ip], ip_version=IPVersion.V4Only)

    svc_properties = {
        "session": CONFIG["SESSION"],
        "impl": "udp_to_lsl"
    }
    
    svc_info = ServiceInfo(
        type_="_pbudp._udp.local.",
        name=f"udp_to_lsl on {socket.gethostname()}._pbudp._udp.local.",
        addresses=[socket.inet_aton(host_ip)],
        port=CONFIG["PORT"],
        properties=svc_properties,
    )

    print("[broadcaster] Registering Bonjour/Zeroconf service...")
    print(f"  - Name: {svc_info.name}")
    print(f"  - Type: {svc_info.type}")
    print(f"  - IP: {host_ip}")
    print(f"  - Port: {CONFIG['PORT']}")
    print(f"  - Session: {CONFIG['SESSION']}")
    
    try:
        zc.register_service(svc_info)
        print("[broadcaster] Service registered. Broadcasting... (Press Ctrl+C to exit)")
        # 保持脚本运行以持续广播
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[broadcaster] Keyboard interrupt received.")
    finally:
        print("[broadcaster] Unregistering service and closing.")
        zc.unregister_service(svc_info)
        zc.close()


if __name__ == "__main__":
    main()