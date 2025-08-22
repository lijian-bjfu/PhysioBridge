//  UDPSenderService.swift
//  PolarBridge
//  轻量 UDP 发送服务（仅给标记用）
//  UdpSender负责数据发送。这个程序服务只负责标记的 UDP 发送，
//  互不影响。在“应用设置”处把它的目标也更新一下，保证标记与数据同目标。

// UDPSenderService.swift
import Foundation
import Network

final class UDPSenderService {
    static let shared = UDPSenderService()

    private var host: String = AppConfig.defaultUDPHost
    private var port: UInt16 = UInt16(clamping: AppConfig.defaultUDPPort)
    private var connection: NWConnection? = nil
    private let queue = DispatchQueue(label: "udp.sender.service")

    func update(host: String, port: Int) {
        self.host = host
        self.port = UInt16(clamping: port)
        recreateConnection()
        print("[UDPSenderService] target -> \(host):\(self.port)")
    }

    private func recreateConnection() {
        connection?.cancel()
        let p = NWEndpoint.Port(rawValue: self.port)!
        let conn = NWConnection(host: NWEndpoint.Host(self.host), port: p, using: .udp)
        connection = conn
        print("[UDPSenderService] recreateConnection -> \(self.host):\(self.port)")
        // 跟踪连接状态，方便定位 UDP “拒绝连接”的时机
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[UDPSenderService] state=ready \(self.host):\(self.port)")
            case .waiting(let err):
                print("[UDPSenderService] state=waiting \(err)")
            case .failed(let err):
                print("[UDPSenderService] state=failed \(err)")
            case .cancelled:
                print("[UDPSenderService] state=cancelled")
            case .setup:
                print("[UDPSenderService] state=setup")
            case .preparing:
                print("[UDPSenderService] state=preparing")
            @unknown default:
                print("[UDPSenderService] state=unknown")
            }
        }

        conn.start(queue: queue)
    }

    func send(_ text: String, onDelivered: (() -> Void)? = nil) {
        let data = Data(text.utf8)
        if connection == nil { recreateConnection() }
        connection?.send(content: data, completion: .contentProcessed({ err in
            if let err = err {
                print("[UDPSenderService][ERROR] \(err)")
            } else {
                print("[UDPSenderService] send ok")
                // ★ 统一切回主线程再调回调
                if let onDelivered = onDelivered {
                    Task { @MainActor in onDelivered() }
                }
            }
        }))
    }
}


