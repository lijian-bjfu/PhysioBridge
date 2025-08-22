//
//  UdpMarkerBridge.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//  订阅 MarkerBus，把事件转为 JSON 并发送到 UDP 目标。初始化一次即可（在视图出现时触发）。

// UdpMarkerBridge.swift
import Foundation
import Combine

final class UdpMarkerBridge {
    static let shared = UdpMarkerBridge()
    private var bag = Set<AnyCancellable>()

    private init() {
        MarkerBus.shared.subject
            .sink { ev in
                var dict: [String: Any] = [
                    "type": "marker",
                    "label": ev.label,
                    "t_device": ev.t_device,
                    "packet_id": ev.packet_id
                ]
                if let note = ev.note { dict["note"] = note }

                if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
                   let text = String(data: data, encoding: .utf8) {
                    UDPSenderService.shared.send(text) {
                        // 确保回调里更新 Store 也在主线程
                        Task { @MainActor in
                            AppStore.shared.markerCount += 1
                        }
                    }
                    print("[UdpMarkerBridge] sent -> \(text)")
                }
            }
            .store(in: &bag)
    }
}

 
