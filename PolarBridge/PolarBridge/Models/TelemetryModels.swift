//
//  TelemetryModels.swift
//  PolarBridge
//
//  Created by lijian on 8/24/25.
//  设定记录数据的格式

import Foundation

/// 统一的遥测数据包协议（所有流的公共字段）
/// - type: 数据类型（"hr" | "rr" | "ecg" | "acc" | "marker"）
/// - device: 设备名（当前固定 "H10"，后续可扩展）
/// - t_device: 设备侧时间戳（秒，Double）。MVP 用 iPhone 本地时间，后续切换 Polar 时间源。
/// - seq: 流内自增序号，用于丢包检测（可选）
protocol TelemetryPacket: Codable {
    var type: String { get }
    var device: String { get }
    var t_device: Double { get }
    var seq: UInt64? { get }
}

// MARK: - 各流数据结构

/// 心率（约 1 Hz，单位 bpm）
struct HRPacket: TelemetryPacket {
    var type = "hr"
    let device: String
    let t_device: Double
    let seq: UInt64?
    let bpm: Int
}

/// 心搏间期 RR（单位 ms）。Polar 回调可能一次带多个 RR，我们按条发出多条 JSON。
struct RRPacket: TelemetryPacket {
    var type = "rr"
    let device: String // 哪个设备发的
    let t_device: Double // 什么时候发的
    let seq: UInt64?
    let ms: Int
}

/// 心电（ECG，批量发送，单位 μV）
/// - fs: 采样率（H10 为 130）
/// - uV: 批量样本数组（Int μV）
/// - n: 样本数冗余字段，便于下游快速校验
struct ECGPacket: TelemetryPacket {
    var type = "ecg"
    let device: String
    let t_device: Double
    let seq: UInt64?
    let fs: Int
    let uV: [Int]
    let n: Int
}

/// 加速度（三轴，批量发送，单位 mG）
/// - fs: 采样率（如 50）
/// - mG: [[x,y,z], ...]，整数 mG
/// - n: 批量样本数
/// - range_g: 量程 2/4/8（单位 g）
struct ACCPacket: TelemetryPacket {
    var type = "acc"
    let device: String
    let t_device: Double
    let seq: UInt64?
    let fs: Int
    let mG: [[Int]]
    let n: Int
    let range_g: Int
}

/// 实验阶段等标注事件（可选）
struct MarkerPacket: TelemetryPacket {
    var type = "marker"
    let device: String
    let t_device: Double
    let seq: UInt64?
    let label: String
}

/// 用于记录受试者及会话编号
struct SessionMetaPacket: TelemetryPacket {
    var type = "session_meta"
    let device: String       // 建议固定 "app"
    let t_device: Double
    let seq: UInt64?         // 可不填
    let pid: String          // 参与者编号
    let session: String      // 测试编号
}


// MARK: - 编码器

enum TelemetryEncoder {
    static let json: JSONEncoder = {
        let enc = JSONEncoder()
        // enc.outputFormatting = [.withoutEscapingSlashes]   // 如需更漂亮的输出再打开
        return enc
    }()

    /// 编码为 UTF-8 字符串，便于沿用 UDPSenderService.send(_ string:)
    static func encodeToJSONString<T: Encodable>(_ value: T) -> String? {
        do {
            let data = try json.encode(value)
            return String(data: data, encoding: .utf8)
        } catch {
            print("[TelemetryEncoder] encode error: \(error)")
            return nil
        }
    }
}
