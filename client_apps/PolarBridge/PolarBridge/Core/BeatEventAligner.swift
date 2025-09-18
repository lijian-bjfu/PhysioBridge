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
            
            // >>> DEBUG: show total and first step
            #if DEBUG
            let total = rrsMs.reduce(0, +)
            print("[BEATALIGN][HIST] lastEvent=\(String(format:"%.6f", last)) totalMs=\(total)ms")
            #endif
            
            for ms in rrsMs {
                t += TimeInterval(ms) / 1000.0
                times.append(t)
            }
            st.lastEventTime = times.last
        } else {
            // 无历史：以“本批总时长回溯到 tHost”为锚
            let total = rrsMs.reduce(0, +)
            var t = tHost - TimeInterval(total) / 1000.0
            
            // >>> DEBUG: show anchor calculation
            #if DEBUG
            print("[BEATALIGN][NEW ] tHost=\(String(format:"%.6f", tHost)) totalMs=\(total)ms anchorStart=\(String(format:"%.6f", t))")
            #endif
            
            for ms in rrsMs {
                t += TimeInterval(ms) / 1000.0
                times.append(t)
            }
            
            // >>> DEBUG: after building times (new series)
            #if DEBUG
            print("[BEATALIGN][NEW ] first=\(String(format: "%.6f", times.first!)) last=\(String(format:"%.6f", times.last!))")
            #endif
            
            st.lastEventTime = times.last
        }
        
        // >>> DEBUG: show st update and detect big jumps
        #if DEBUG
        let updated = st.lastEventTime ?? 0.0
        print("[BEATALIGN][OUT ] updated_lastEvent=\(String(format:"%.6f", updated))")
        // detect large jump relative to tHost or relative to previous last if existed
        if let prev = series[k]?.lastEventTime {
            let jump = updated - prev
            if abs(jump) > 5.0 {
                print("[BEATALIGN][WARN] large_jump=\(String(format: "%.3f", jump))s (prev=\(String(format:"%.6f", prev)), new=\(String(format:"%.6f", updated)))")
            }
        } else {
            // also compare updated with tHost: if times.last is far from tHost (>> 1s), warn
            let delta = updated - tHost
            if abs(delta) > 5.0 {
                print("[BEATALIGN][WARN] astEvent (\(String(format:"%.6f", updated))) is \(String(format:"%.1f", delta))s away from tHost (\(String(format:"%.6f", tHost))).")
            }
        }
        #endif
        
        
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
