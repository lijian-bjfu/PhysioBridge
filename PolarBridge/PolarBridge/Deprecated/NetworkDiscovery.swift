//
//  NetworkDiscovery.swift
//  PolarBridge
//
//  Created by lijian on 8/24/25.
//

// 本来此文件用于发现电脑端udp_to_lsl.py所提供的电脑端IP地址，以此作为UDP的发送目标。但是折腾半天也没成功。这个功能不光是代码层面，还要在系统和网络上做各种配置超级麻烦。所以目前的方法是让用户自己填写目标UDP地址，此文件弃用。

import Foundation
import Network
import Darwin

/// Bonjour 自动发现 udp_to_lsl.py，并把解析到的 IPv4/端口写入 UserDefaults。
/// 发现到首个服务即自动应用；后续可扩展为“多候选列表+手动选择”。
final class NetworkDiscovery: NSObject, ObservableObject {
    @Published var resolvedHost: String?
    @Published var resolvedPort: Int = 0

    private let browserAny = NetServiceBrowser()    // 浏览空域 ""
    private let browserLocal = NetServiceBrowser()  // 浏览 "local."
    private var services: [NetService] = []
    private var foundCount = 0

    func start() {
        // 空域
        browserAny.delegate = self
        browserAny.includesPeerToPeer = true
        browserAny.searchForServices(ofType: "_pbudp._udp.", inDomain: "")
        print("[AUTO] browser.start issued (domain=\"\")")

        // local.
        browserLocal.delegate = self
        browserLocal.includesPeerToPeer = true
        browserLocal.searchForServices(ofType: "_pbudp._udp.", inDomain: "local.")
        print("[AUTO] browser.start issued (domain=\"local.\")")

        foundCount = 0
    }

    func stop() {
        browserAny.stop()
        browserLocal.stop()
        services.removeAll()
        print("[AUTO] browser stopped (both domains)")
    }
}

extension NetworkDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        print("[AUTO] browser will search _pbudp._udp")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("[AUTO] browser didNotSearch: \(errorDict)")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        foundCount += 1
        print("[AUTO] didFind: \(service.name) (\(service.type))")
        // 仅解析我们自己的桥接器实例：Python 端的服务名形如 "udp_to_lsl on <HostName>"
        guard service.name.hasPrefix("udp_to_lsl on ") else {
            print("[AUTO] ignore non-target service: \(service.name)")
            return
        }
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 3.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let (ipv4, port) = Self.extractIPv4AndPort(from: sender) else {
            print("[AUTO] resolve ok but no IPv4 addr")
            return
        }

        // 读取 TXT 记录，若存在 impl=udp_to_lsl 则优先应用
        var ok = true
        if let txt = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txt)
            if let implData = dict["impl"], let impl = String(data: implData, encoding: .utf8) {
                ok = (impl == "udp_to_lsl")
            }
        }
        guard ok else {
            print("[AUTO] resolved non-target (impl!=udp_to_lsl), ignore \(ipv4):\(port)")
            return
        }

        print("[AUTO] will apply resolved host: \(ipv4):\(port)")
        DispatchQueue.main.async {
            self.resolvedHost = ipv4
            self.resolvedPort = port
            UserDefaults.standard.set(ipv4, forKey: "udpHost")
            UserDefaults.standard.set(port, forKey: "udpPort")
            print("[AUTO] Bonjour resolved \(ipv4):\(port) -> applied to udpHost/udpPort")
        }
    }


    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("[AUTO] didNotResolve: \(errorDict)")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        print("[AUTO] browser did stop search (found=\(foundCount))")
    }

    static func extractIPv4AndPort(from service: NetService) -> (String, Int)? {
        guard let addrs = service.addresses else { return nil }

        // 收集候选并打分
        var candidates: [(score: Int, ip: String, port: Int)] = []

        for data in addrs {
            if data.count < MemoryLayout<sockaddr_in>.size { continue }

            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let sa = raw.bindMemory(to: sockaddr.self)
                guard sa.count > 0, sa[0].sa_family == sa_family_t(AF_INET) else { return }

                let sin = raw.bindMemory(to: sockaddr_in.self)[0]
                var addr = sin.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))

                let ip = String(cString: buf)
                let port = Int(UInt16(bigEndian: sin.sin_port))

                // 打分：分数越小越好
                let score: Int = {
                    if ip.hasPrefix("192.168.") { return 0 }
                    if ip.hasPrefix("10.")      { return 1 }
                    if ip.hasPrefix("172.") {
                        // 172.16–31 视为私网
                        let comps = ip.split(separator: ".")
                        if comps.count > 1, let second = Int(comps[1]), (16...31).contains(second) {
                            return 2
                        }
                    }
                    if ip.hasPrefix("169.254.") { return 9 }   // 链路本地，最不推荐
                    if ip.hasPrefix("127.")     { return 99 }  // 回环，绝不使用
                    return 5  // 其它公网/未归类，居中
                }()

                candidates.append((score, ip, port))
            }
        }

        // 选最优
        if let best = candidates.sorted(by: { $0.score < $1.score }).first {
            return (best.ip, best.port)
        }
        return nil
    }

    

}
