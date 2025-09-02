//
//  PingPongResponder.swift
//  PolarBridge
//
//  Created by lijian on 9/1/25.
//

// 与mac端通讯，用于测试延迟

import Foundation
import Network

/// 绑定在你现有的 UDP NWConnection 上，用于接收 ping 并回 pong。
final class PingPongResponder {

    static let shared = PingPongResponder()
    private init() {}

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "pp.responder")

    /// 在你已有的 UDP 连接 start() 之后调用一次即可
    func attach(to connection: NWConnection) {
        // 避免重复绑定
        if conn === connection { return }
        conn = connection
        startReceiveLoop()
    }

    private func startReceiveLoop() {
        guard let conn = conn else { return }
        conn.receiveMessage { [weak self] (data, context, isComplete, error) in
            if let data, !data.isEmpty {
                self?.handle(datagram: data)
            }
            // 继续下一轮
            self?.startReceiveLoop()
        }
    }

    private func handle(datagram: Data) {
        // 只关心 {"type":"ping","t0_pc":...}
        guard let obj = try? JSONSerialization.jsonObject(with: datagram) as? [String: Any],
              let typ = obj["type"] as? String, typ == "ping",
              let t0pc = obj["t0_pc"] as? Double
        else { return }

        let t1 = Date().timeIntervalSince1970
        var payload: [String: Any] = [
            "type": "pong",
            "t0_pc": t0pc,
            "t1_ph": t1,
            // t2 在真正发出前再次取一次
        ]
        
        // ← NEW: 把对方带来的 device 透传回去
        if let dev = obj["device"] as? String {
            payload["device"] = dev
        }

        // 发送：沿用同一条 NWConnection 原路返回
        sendJSON(payload)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let conn = conn else { return }
        var d = dict
        d["t2_ph"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }
}

