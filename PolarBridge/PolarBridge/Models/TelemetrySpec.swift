//
//  TelemetrySpec.swift
//  PolarBridge
//
//  Created by lijian on 8/24/25.
//  放置与格式相关的常量、元数据键名，避免过于零散的插在代码各处
import Foundation

enum TelemetrySpec {
    static let deviceNameH10 = "H10"

    enum Units {
        static let bpm = "bpm"
        static let ms  = "ms"
        static let uV  = "uV"
        static let mG  = "mG"
    }

    enum Streams {
        // 与 Python 侧 LSL 命名习惯保持一致（仅供参考/对齐）
        static let hr  = "PB_HR"
        static let rr  = "PB_RR"
        static let ecg = "PB_ECG"
        static let acc = "PB_ACC"
        static let mrk = "PB_MARKERS"
    }
}
