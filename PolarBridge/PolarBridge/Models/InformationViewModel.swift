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
}

@MainActor
final class InformationViewModel: ObservableObject {
    
    // MARK: - 依赖 (Dependencies)
    private let store: AppStore
    private var cancellables = Set<AnyCancellable>()

    // MARK: - UI State Properties
    
    /// **核心状态**: 用于驱动 View 在“空态”和“数据态”之间切换
    @Published var hasDevice: Bool = false
    // --- “采集信息”卡片所需的数据 ---
    @Published var isCollecting: Bool = false
    
    // --- “空态” UI 所需的数据 ---
    @Published private var bluetoothOn: Bool = false
    var bluetoothStatus: (text: String, color: Color) {
        if bluetoothOn {
            return ("已开启", .green) // 蓝牙开启时显示绿色
        } else {
            return ("未开启", .red)  // 蓝牙未开启时显示红色
        }
    }
    var emptyPromptText: String {
            bluetoothOn ? "等待您连接或发现 Polar 设备" : "请您前往系统设置或控制中心打开蓝牙"
        }
    
    // --- “数据态” UI 所需的数据 (M2.2 阶段) ---
    @Published var deviceName: String = "—"
    @Published var deviceID: String = "—"
    @Published var connectionSummary: (text: String, color: Color) = ("未连接", .gray)
    @Published var supportedFeatures: [String] = []

    // MARK: - Initializer
    init(store: AppStore) {
        self.store = store
        print("InformationViewModel Initialized with AppStore")
        
        // 订阅 AppStore 中两个设备的状态变化
        store.$h10State
            .combineLatest(store.$verityState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] h10State, verityState in
                self?.update(h10: h10State, verity: verityState)
            }
            .store(in: &cancellables)
        
        // 订阅采集状态
        store.$isCollecting
            .receive(on: DispatchQueue.main)
            // 将从 store 接收到的新值，赋给 viewModel 自己的 isCollecting 属性
            .sink { [weak self] isCollectingValue in
                self?.isCollecting = isCollectingValue
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 私有方法
    
    /// 提供一个公共方法，供 View 更新蓝牙状态
    func updateBluetoothState(isOn: Bool) {
        self.bluetoothOn = isOn
    }
    
    /// 当任一设备状态更新时，此方法被调用
    private func update(h10: DeviceState, verity: DeviceState) {
        // 1. 更新 hasDevice 状态
        // 只要任一设备不再是 .not_found 状态，就认为“已发现设备”
        self.hasDevice = (h10 != .not_found || verity != .not_found)
        
        // 2. 更新连接状态的文本和颜色
        if h10 == .connected || verity == .connected {
            self.connectionSummary = ("已连接", .green)
        } else if h10 == .connecting || verity == .connecting {
            self.connectionSummary = ("连接中...", .yellow)
        } else if h10 == .discovered || verity == .discovered {
            self.connectionSummary = ("已发现，未连接", .blue)
        } else {
            self.connectionSummary = ("未发现设备", .gray)
        }
        
        // 3. 更新支持的数据流
        // AppStore.availableSignals 已经为我们计算好了这个集合
        self.supportedFeatures = store.availableSignals.map { $0.title }.sorted()
        
        // 注意：deviceName 和 deviceID 需要从 PolarManager 获取，
        // AppStore 目前未直接暴露。我们将在后续任务中完善这部分。
    }
}
