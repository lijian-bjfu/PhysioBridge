import SwiftUI

enum DeviceState: String, CaseIterable, Identifiable {
    case not_found, discovered, connecting, connected, failed, permission_missing
    var id: String { rawValue }
    var isConnected: Bool { self == .connected }

    var subtitle: String {
        switch self {
        case .not_found: return "未连接"
        case .discovered: return "可发现"
        case .connecting: return "正在连接…"
        case .connected: return "已连接"
        case .failed: return "连接失败"
        case .permission_missing: return "权限未开"
        }
    }
    var symbol: String {
        switch self {
        case .not_found: return "wifi.slash"
        case .discovered: return "wifi"
        case .connecting: return "clock.arrow.2.circlepath"
        case .connected: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon.fill"
        case .permission_missing: return "lock.slash.fill"
        }
    }
    var tint: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .permission_missing: return .yellow
        case .discovered: return .blue
        case .not_found: return .secondary
        }
    }
}

enum DataSource: String, CaseIterable, Identifiable {
    case ppi, ppg, ecg, rr, vhr, vacc, hhr, hacc     // ← 新增 rr、acc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ppi: return "PPI"
        case .ppg: return "PPG"
        case .ecg: return "ECG"
        case .rr:  return "RR"
        case .vhr:  return "VHR"
        case .hhr:  return "HHR"
        case .vacc: return "VACC"
        case .hacc: return "HACC"
        }
    }
}


