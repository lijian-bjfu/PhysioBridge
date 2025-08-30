import Foundation
import Combine
import SwiftUI

// MARK: - Helper Enums (提前定义，供 ViewModel 和 View 使用)
// 这些枚举后续会根据真实状态进行扩充

enum ConnectionStatus: String {
    case notConnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case error = "异常"
}

enum SignalQuality: String {
    case none = "—"
    case poor = "差"
    case fair = "中"
    case good = "良"
    case excellent = "优"
}

struct StreamInfo: Identifiable {
    let id: UUID = UUID()
    let name: String          // "ECG", "ACC"
    let params: String        // "130 Hz | 1 ch | uV"
    var lossRate: Double?   // 0.003 (0.3%), nil 表示不适用 (如 RR)
    let showsLossRow: Bool
}

// 设备信息存储结构
struct ConnectionInfo: Equatable {
    let text: String
    let color: Color
    // 因为 text (String) 和 color (Color) 都是 Equatable 的，
    // 所以 ConnectionInfo 可以自动获得 Equatable 的能力，无需手写 ==
}

struct DeviceSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    let battery: Int?
    let rssi: Int?
    let supported: [String]
    // 将两个独立的属性合并为一个元组
    let connection: ConnectionInfo
}

@MainActor
final class InformationViewModel: ObservableObject {

    // 依赖
    private let store: AppStore
    private let pm = PolarManager.shared
    private var cancellables = Set<AnyCancellable>()

    // 空态/数据态
    @Published var hasDevice: Bool = false
    @Published var isCollecting: Bool = false

    // 空态文案（蓝牙由 View 注入，保持你原有做法）
    @Published private var bluetoothOn: Bool = false
    var bluetoothStatus: (text: String, color: Color) {
        bluetoothOn ? ("已开启", .green) : ("未开启", .red)
    }
    var emptyPromptText: String {
        bluetoothOn ? "等待您连接或发现 Polar 设备" : "请您前往系统设置或控制中心打开蓝牙"
    }

    // 数据态：多设备快照数组（InformationView 将 ForEach 渲染它）
    @Published var devices: [DeviceSnapshot] = []
    @Published var connectionSummary: (text: String, color: Color) = ("未连接", .gray)
    
    // 采集信息摘要
    @Published var streamSummaries: [StreamInfo] = []
    // 被试编号信息
    @Published var participantText: String = "—"
    @Published var sessionText: String = "—"


    // MARK: init
    init(store: AppStore) {
        self.store = store
        bindDevice()
        bindStreams()
        bindSession()
    }

    // View 注入蓝牙电源状态
    func updateBluetoothState(isOn: Bool) {
        bluetoothOn = isOn
    }

    // MARK: - 设备信息
    // 绑定全局状态与设备源，驱动 UI
    private func bindDevice() {
        // 采集状态
        store.$isCollecting
            .receive(on: RunLoop.main)
            .assign(to: &$isCollecting)

        // 连接状态变化会影响颜色与 hasDevice
        store.$h10State
            .combineLatest(store.$verityState)
            .receive(on: RunLoop.main)
            .sink { [weak self] h10, verity in
                self?.updateConnectionSummary(h10: h10, verity: verity)
                self?.rebuildDevices()
            }
            .store(in: &cancellables)

        // PolarManager 的“事实来源”：发现列表 + 已连接的两个 ID
        Publishers.MergeMany(
            pm.$discovered.map { _ in () }.eraseToAnyPublisher(),
            pm.$connectedH10Id.map { _ in () }.eraseToAnyPublisher(),
            pm.$connectedVerityId.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildDevices() }
        .store(in: &cancellables)

        // 首次同步
        rebuildDevices()
        updateConnectionSummary(h10: store.h10State, verity: store.verityState)
    }

    
    // 根据连接态与已发现信息，重建 devices 数组
    private func rebuildDevices() {
        var out: [DeviceSnapshot] = []

        if let h10 = pm.connectedH10Id, let snap = snapshot(for: h10, kind: .h10) {
            out.append(snap)
        }
        if let ver = pm.connectedVerityId, let snap = snapshot(for: ver, kind: .verity) {
            out.append(snap)
        }

        devices = out
        hasDevice = !out.isEmpty
    }

    private enum Kind { case h10, verity }

    // 把 PolarManager 的发现条目 + AppStore 的连接态，拼成展示快照
    private func snapshot(for id: String, kind: Kind) -> DeviceSnapshot? {
        let d = pm.discovered.first { $0.id == id }
        let name = d?.name ?? id
        let rssi = d?.rssi
        let bat  = d?.batteryLevel

        let (text, color): (String, Color) = {
            switch kind {
            case .h10:   return stateTextColor(store.h10State)
            case .verity:return stateTextColor(store.verityState)
            }
        }()

        let supported: [String] = {
            // 临时静态描述；若后续要按实际订阅/能力生成，再从 PolarManager 的 capabilities 汇总
            switch kind {
            case .h10:   return ["ECG", "RR", "HR", "ACC(H10)"]
            case .verity:return ["PPG", "PPI", "VHR", "ACC(Verity)"]
            }
        }()

        let connectionInfo = ConnectionInfo(text: text, color: color)

        return DeviceSnapshot(
            id: id,
            name: name,
            battery: bat,
            rssi: rssi,
            supported: supported,
            connection: connectionInfo // 使用刚刚创建的实例
        )
    }

    private func stateTextColor(_ s: DeviceState) -> (String, Color) {
        switch s {
        case .connected:   return ("已连接", .green)
        case .connecting:  return ("连接中...", .yellow)
        case .discovered:  return ("已发现，未连接", .blue)
        case .not_found:   return ("未发现设备", .gray)
        case .failed:      return ("连接失败", .red)
        case .permission_missing: return ("权限未开", .red)
        }
    }

    private func updateConnectionSummary(h10: DeviceState, verity: DeviceState) {
        // 连接总览的文案（供旧 UI 使用）
        if h10 == .connected || verity == .connected {
            connectionSummary = ("已连接", .green)
        } else if h10 == .connecting || verity == .connecting {
            connectionSummary = ("连接中...", .yellow)
        } else if h10 == .discovered || verity == .discovered {
            connectionSummary = ("已发现，未连接", .blue)
        } else if h10 == .failed || verity == .failed {
            connectionSummary = ("连接失败", .red)
        } else {
            connectionSummary = ("未发现设备", .gray)
        }
    }
    
    // MARK: - 信号采集
    
    private func deviceId(for kind: SignalKind) -> String? {
        switch kind {
        case .ppg, .ppi, .vhr, .vacc: return pm.connectedVerityId
        case .ecg, .hhr, .rr, .hacc:  return pm.connectedH10Id
        }
    }
    
    private func rebuildStreamSummaries() {
        // 只有在采集中才展示详情；否则清空列表
        guard isCollecting else {
            streamSummaries = []
            return
        }

        // 沿用 CollectView 的口径，把 selectedSignals 转成“名称 + 参数字符串”
        // 参考 CollectView 中 details 的拼装逻辑
        // （依赖 SignalKind.title/defaultFs/defaultRangeG/unit/shortDesc）
        let kinds = Array(store.selectedSignals).sorted { $0.rawValue < $1.rawValue }

        streamSummaries = kinds.map { kind in
            let name = kind.title

            // 参数字符串：与采集页一致
            let params: String = {
                if let fs = kind.defaultFs, let rg = kind.defaultRangeG, (kind == .vacc || kind == .hacc) {
                    return "\(kind.unit) @\(fs)Hz，±\(rg)G；\(kind.shortDesc)"
                } else if let fs = kind.defaultFs {
                    return "\(kind.unit) @\(fs)Hz；\(kind.shortDesc)"
                } else {
                    return "\(kind.unit)；\(kind.shortDesc)"
                }
            }()
            
            // 哪些流需要显示丢包：连续流才有
                let needsLoss: Bool = {
                    switch kind {
                    case .vhr, .hhr, .rr, .ppi: return false        // 事件/派生流：不显示
                    default:              return true         // ECG/HACC/VACC/PPG/VHR 等：显示
                    }
                }()
            
            let devId = deviceId(for: kind)
            let loss = devId.flatMap { pm.loss60sByDeviceAndKind[$0]?[kind] }

            return StreamInfo(name: name, params: params, lossRate: loss, showsLossRow: needsLoss)
        }
    }

    // 在 bind() 里追加订阅，驱动摘要重算
    private func bindStreams() {
        // 采集状态变化会影响是否展示摘要
        store.$isCollecting
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildStreamSummaries() }
            .store(in: &cancellables)

        // 选择集变化会更新摘要（仅在 isCollecting 为真时生效）
        store.$selectedSignals
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildStreamSummaries() }
            .store(in: &cancellables)
        
        // 丢包数据流
        pm.$loss60sByDeviceAndKind
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildStreamSummaries() }
            .store(in: &cancellables)

        // 首次同步
        rebuildStreamSummaries()
    }
    
    // MARK: - 被试编号信息
    private func bindSession() {
        store.$subjectID
            .map { $0?.isEmpty == false ? $0! : "—" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .assign(to: &$participantText)

        store.$trialID
            .map { $0.isEmpty ? "—" : $0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .assign(to: &$sessionText)
    }
}

