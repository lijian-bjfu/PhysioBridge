//
//  BeatEventAligner.swift
//  PolarBridge
//
//  Created by lijian on 8/27/25.
//
// 用于rr-ppi事件时间对齐
import Foundation

/// 事件流类型（只为区分同一设备上的不同来源）
enum BeatStream: String {
    case rr   = "RR"
    case ppi  = "PPI"
}

/// 把 RR/PPI 的不等间隔事件映射到统一的本地时间轴
/// 线程安全：内部用 NSLock 保护状态
final class BeatEventAligner {

    static let shared = BeatEventAligner()

    private struct SeriesState {
        var lastEventTime: TimeInterval? = nil  // 上一心跳事件时间（本地）
    }

    // key = "\(stream.rawValue)#\(deviceId)"
    private var series: [String: SeriesState] = [:]
    private let lock = NSLock()

    private func key(_ stream: BeatStream, _ deviceId: String) -> String {
        return "\(stream.rawValue)#\(deviceId)"
    }

    /// 重置某条事件流（断线/切源时可调用）
    func reset(stream: BeatStream, deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        series.removeValue(forKey: key(stream, deviceId))
    }

    /// 对 RR 批次进行时间对齐
    /// - Parameters:
    ///   - deviceId: 设备 ID（用于区分不同设备的状态）
    ///   - rrsMs: 本批 RR 序列（毫秒），顺序为“事件发生的先后顺序”
    ///   - tHost: 本批到达时刻（本地时间）
    /// - Returns: 与 rrsMs 一一对应的事件时间数组（本地时间轴）
    func alignRRBatch(deviceId: String, rrsMs: [Int], tHost: TimeInterval) -> [TimeInterval] {
        guard !rrsMs.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        let k = key(.rr, deviceId)
        var st = series[k] ?? SeriesState()

        var times: [TimeInterval] = []
        if let last = st.lastEventTime {
            // 有历史：按 rr 依次前推
            var t = last
            for ms in rrsMs {
                t += TimeInterval(ms) / 1000.0
                times.append(t)
            }
            st.lastEventTime = times.last
        } else {
            // 无历史：以“本批总时长回溯到 tHost”为锚
            let total = rrsMs.reduce(0, +)
            var t = tHost - TimeInterval(total) / 1000.0
            for ms in rrsMs {
                t += TimeInterval(ms) / 1000.0
                times.append(t)
            }
            st.lastEventTime = times.last
        }
        series[k] = st
        return times
    }

    /// 对单条 PPI 进行时间对齐
    /// - Parameters:
    ///   - deviceId: 设备 ID
    ///   - ms: 与上一搏的间隔（毫秒）
    ///   - tHost: 样本到达时刻（本地时间）
    /// - Returns: 该事件的时间（本地时间轴）
    func alignPPI(deviceId: String, ms: Int, tHost: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let k = key(.ppi, deviceId)
        var st = series[k] ?? SeriesState()

        let tEvent: TimeInterval
        if let last = st.lastEventTime {
            tEvent = last + TimeInterval(ms) / 1000.0
        } else {
            // 首样本：以到达时刻为锚
            tEvent = tHost
        }
        st.lastEventTime = tEvent
        series[k] = st
        return tEvent
    }
}
