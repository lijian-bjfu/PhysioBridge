// NetworkInfo.swift
// 本意是识别UDP的目标IP，这个文件用于识别手机本地IP，但这和UDP目标IP完全两码事，概念上就错了，没有卵用的玩意儿，弃用。
import Foundation
import Darwin

/// 读取本机活跃 IPv4（优先 Wi-Fi 接口 en0/en1），以及掩码与 CIDR 前缀。
enum NetworkInfo {

    /// 返回本机首选 IPv4。优先选择 Wi-Fi 接口（en0/en1），否则选任意非回环 IPv4。
    static func deviceIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var best: (name: String, ip: String)? = nil
        var fallback: String? = nil

        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: ifa.ifa_name)
            if name == "lo0" { continue }

            guard let ip = ipv4String(from: addr) else { continue }

            if name.hasPrefix("en0") || name.hasPrefix("en1") {
                best = (name, ip)
            } else if fallback == nil {
                fallback = ip
            }
        }
        return best?.ip ?? fallback
    }

    /// 返回本机与首选 IPv4 对应接口的子网掩码（点分十进制）。
    static func subnetMask() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        let targetIP = deviceIPv4()
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard let ip = ipv4String(from: addr), ip == targetIP else { continue }
            if let mask = ifa.ifa_netmask, let maskStr = ipv4String(from: mask) {
                return maskStr
            }
        }
        return nil
    }

    /// 返回 CIDR 前缀长度（例如 24）。
    static func cidrPrefixLength() -> Int? {
        guard let maskStr = subnetMask(), let mask = ipv4ToUInt32(maskStr) else { return nil }
        return mask.nonzeroBitCount
    }

    /// 便捷描述，如 "192.168.1.23/24"。
    static func lanDescription() -> String {
        let ip = deviceIPv4() ?? "0.0.0.0"
        if let cidr = cidrPrefixLength() { return "\(ip)/\(cidr)" }
        return ip
    }

    /// 用于“分网段记忆”的键，例如 "192.168.1.0/24"。
    static func lanKeyForMemory() -> String? {
        guard let ipStr = deviceIPv4(), let maskStr = subnetMask(),
              let ip = ipv4ToUInt32(ipStr), let mask = ipv4ToUInt32(maskStr) else { return nil }
        let network = ip & mask
        let cidr = mask.nonzeroBitCount
        return "\(uint32ToIPv4(network))/\(cidr)"
    }

    // MARK: - Helpers

    /// 将 AF_INET 的 sockaddr 指针安全转换为 IPv4 字符串。
    private static func ipv4String(from sa: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let sa = sa, sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        var result: String?
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sinPtr in
            var sin = sinPtr.pointee
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            result = String(cString: buf)
        }
        return result
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        var addr = in_addr()
        if inet_pton(AF_INET, ip, &addr) == 1 {
            // in_addr.s_addr 是网络序；转为主机序 UInt32
            return UInt32(bigEndian: addr.s_addr)
        }
        return nil
    }

    private static func uint32ToIPv4(_ v: UInt32) -> String {
        // 将主机序 UInt32 写回网络序再转字符串
        var be = in_addr(s_addr: in_addr_t(bigEndian: v))
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &be, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}

