//
//  MarkerBus.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//  标记事件与总线：“Bus”就是总线/事件中枢：任何地方想发“标记”（基线开始、诱导开始/结束等）都只调用 MarkerBus.shared.emit(...)。下游有若干订阅者（现在是 UdpMarkerBridge，未来还可以是本地日志、屏幕提示、振动提醒等）同时收到这条统一格式的事件，互不耦合。

import Foundation
import Combine

enum MarkerLabel: String, Codable {
    case baseline_start
    case stim_start
    case stim_end
    case intervention_start
    case intervention_end
    case stop
    case custom_events
}

struct MarkerEvent: Codable {
    let label: String
    let t_device: TimeInterval   // 设备本机时间戳（秒）
    let packet_id: Int
    let note: String?            // 备注（可选）
}

final class MarkerBus {
    static let shared = MarkerBus()
    let subject = PassthroughSubject<MarkerEvent, Never>()
    private var nextId = 0

    func emit(label: MarkerLabel, note: String? = nil) {
        nextId += 1
        let ev = MarkerEvent(
            label: label.rawValue,
            t_device: Date().timeIntervalSince1970,
            packet_id: nextId,
            note: note
        )
        subject.send(ev)
        print("[MarkerBus] emit -> \(ev.label) #\(ev.packet_id)")
    }
}


