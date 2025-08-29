//
//  BluetoothManager.swift
//  PolarBridge
//
//  Created by lijian on 8/29/25.
//

import Foundation
@preconcurrency import CoreBluetooth
import Combine

/// BluetoothManager
/// 一个独立的、只负责报告系统蓝牙状态的单例服务。
@MainActor
final class BluetoothManager: NSObject {
    
    // 单例实例
    static let shared = BluetoothManager()
    
    @Published var bluetoothState: CBManagerState = .unknown
    private var central: CBCentralManager!
    
    private var centralManager: CBCentralManager!

    private override init() {
        super.init()
        // dispatchQueue: nil 表示在主线程队列上处理事件，对于更新 UI 状态是安全的。
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
        // 初始化时同步一次（可能是 .unknown；真正状态在回调里更新）
        let s = central.state
        DispatchQueue.main.async { [weak self] in self?.bluetoothState = s }
        print("[BluetoothManager] Initialized and started monitoring.")
    }
}

// MARK: - CBCentralManagerDelegate Conformance
// 单独放在 extension 里并标注 nonisolated，满足协议“非隔离”的签名要求
extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
        // 回到主线程再写 Published，避免跨线程触发 UI 更新
        DispatchQueue.main.async { [weak self] in
            let state = central.state
            self?.bluetoothState = state
            
            switch central.state {
            case .poweredOn:
                print("[BluetoothManager] State updated: ON")
            case .poweredOff:
                print("[BluetoothManager] State updated: OFF")
            case .unauthorized:
                print("[BluetoothManager] State updated: Unauthorized")
            case .unsupported:
                print("[BluetoothManager] State updated: Unsupported")
            case .resetting:
                print("[BluetoothManager] State updated: Resetting")
            case .unknown:
                fallthrough
            @unknown default:
                print("[BluetoothManager] State updated: Unknown")
            }
        }
    }
}
