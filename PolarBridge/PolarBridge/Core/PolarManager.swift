//
//  PolarManager.swift
//  责任：
//    1) 使用 PolarBleSdk 完成 BLE（低功耗蓝牙）设备的扫描、连接/断开；
//    2) 订阅 HR（心率）与 RR 间期（由 HR 流返回的 rrsMs，映射为 IBI/PPI）；
//    3) 将 HR/IBI 以 JSON 文本经 UDP（用户数据报协议）发送至桌面端（你已有 UDPSenderService）；
//    4) 通过 @Published 暴露可观测状态以驱动 UI（设备列表、连接状态、最新 HR、最新 IBI）。
//
//  依赖：PolarBleSdk 6.5.0, RxSwift
//  备注：Polar 6.5 起，心率观察者接口已废弃，须使用 startHrStreaming 进行订阅。
//        下方使用“批→取末样本为当前 HR + 展开 RR 序列”的策略。
//        首次连接成功后立即停止扫描（节能与稳定性）。
//

import Foundation
import CoreBluetooth
import PolarBleSdk
import RxSwift

/// 扫描、连接、订阅 HR/IBI 的集中管理器（单例）。
final class PolarManager: NSObject, ObservableObject {

    // MARK: - Singleton
    static let shared = PolarManager()

    // MARK: - 可观测 UI 状态（SwiftUI 订阅这些字段以更新界面）
    @Published var blePoweredOn: Bool = false          // BLE（低功耗蓝牙）是否开启
    @Published var isScanning: Bool = false            // 是否处于扫描状态
    @Published var discovered: [Discovered] = []       // 扫描到的设备列表
    @Published var connectingId: String? = nil         // 正在连接的 deviceId
    @Published var connectedId: String? = nil          // 已连接的 deviceId

    @Published var lastHr: UInt8 = 0                   // 最新心率（bpm）
    @Published var lastRrMs: [Int] = []                // 最新一批 RR 间期（毫秒），可映射为 IBI/PPI

    /// ISO8601 时间戳格式化器（用于统一日志时间）
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 简单日志函数（带时间戳与标签）
    private func log(_ tag: String, _ message: String) {
        let ts = PolarManager.iso8601.string(from: Date())
        print("\(ts) [\(tag)] \(message)")
    }
    
    /// 扫描项：仅以 deviceId 作为身份标识；name/RSSI 为附属信息
    struct Discovered: Identifiable, Hashable {
        let id: String         // deviceId（唯一标识）
        let name: String
        let rssi: Int          // RSSI（信号强度）
        let connectable: Bool
        // Hash/Equal 默认即可，但在列表更新时我们仅按 id 去重
    }
    /// 扫描起始时间与心跳定时器
    private var scanStartedAt: Date?
    private var scanHeartbeatTimer: DispatchSourceTimer?
    

    // MARK: - Polar SDK 与 RxSwift
    private var api: PolarBleApi!                      // Polar 核心 API。声明为 var 以允许设置其观察者属性
    private let disposeBag = DisposeBag()              // 备用清理袋（当前主要使用手动 Disposable 字段）
    private var scanDisposable: Disposable?            // 扫描订阅
    private var hrDisposable: Disposable?              // HR 流订阅

    // MARK: - 初始化与观察者挂载
    override init() {
        super.init()
        // 实例化 Polar API，并指定所需功能：
        // - feature_hr：心率流（含 RR 间期）
        // - feature_device_info：设备信息（DIS）
        // - feature_battery_info：电池信息
        // - feature_polar_online_streaming：在线流功能（HR 属于此范畴）
        api = PolarBleApiDefaultImpl.polarImplementation(
            .main,
            features: [
                .feature_hr,
                .feature_device_info,
                .feature_battery_info,
                .feature_polar_online_streaming
            ]
        )
        // 挂载必要观察者：电源状态、设备信息、特性就绪、连接生命周期
        api.observer = self
        api.powerStateObserver = self
        api.deviceInfoObserver = self
        api.deviceFeaturesObserver = self
    }

    deinit {
        // 清理可能的订阅，避免泄漏
        scanDisposable?.dispose()
        hrDisposable?.dispose()
    }

    // MARK: - 扫描（仅按名称前缀过滤；UI 层展示列表以供选择）
    /// 开始扫描（可按名称前缀过滤，一般使用 "Polar"）。代码可以扫描周围的蓝牙设备，筛选出设备名以 "Polar" 开头的设备（这是默认设置，可以修改）。所有发现的设备信息（ID, 名称, 信号强度等）会存储在 discovered 数组中，这个数组通过 @Published 标记，意味着它可以直接用于在 SwiftUI 界面上展示一个设备列表。
    func startScan(prefix: String? = "Polar") {
        guard scanDisposable == nil else { return }
        isScanning = true
        scanStartedAt = Date()
        log("SCAN", "开始扫描 prefix=\(prefix ?? "nil")")

        // 每 3 秒打印一次扫描心跳（已发现设备数量与摘要）
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let count = self.discovered.count
            let names = self.discovered.map { "\($0.name)#\($0.id.prefix(4))@\(String($0.rssi))" }
                                       .joined(separator: ", ")
            self.log("SCAN", "心跳: 已发现 \(count) 台设备\(count > 0 ? " [\(names)]" : "")")
        }
        timer.resume()
        scanHeartbeatTimer = timer

        // 10 秒仍未发现设备时给出指引性提示（仅提示一次）
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.isScanning, self.discovered.isEmpty else { return }
            self.log("SCAN", "10 秒内未发现设备。请确认：1) H10 已佩戴并开启；2) 关闭 Polar Flow；3) iPhone 蓝牙已开启。")
        }

        // 启动极化（Polar）SDK 扫描
        scanDisposable = api
            .searchForDevice(withRequiredDeviceNamePrefix: prefix)
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] info in
                    guard let self = self else { return }
                    let d = Discovered(id: info.deviceId, name: info.name, rssi: info.rssi, connectable: info.connectable)
                    if let idx = self.discovered.firstIndex(where: { $0.id == d.id }) {
                        self.discovered[idx] = d
                    } else {
                        self.discovered.append(d)
                        // 对“首次发现”的设备打印更详细的初始快照
                        self.log("DISCOVERY", "首次发现: id=\(info.deviceId) name=\(info.name) rssi=\(info.rssi) connectable=\(info.connectable)")
                    }
                },
                onError: { [weak self] err in
                    self?.isScanning = false
                    self?.scanDisposable = nil
                    self?.log("SCAN", "扫描失败: \(err)")
                }
            )
    }


    /// 停止扫描
    func stopScan() {
        scanDisposable?.dispose()
        scanDisposable = nil
        isScanning = false

        // 停止心跳
        scanHeartbeatTimer?.cancel()
        scanHeartbeatTimer = nil

        // 打印结束摘要
        let elapsed = scanStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let names = discovered.map { "\($0.name)#\($0.id.prefix(4))" }.joined(separator: ", ")
        log("SCAN", "结束。时长=\(String(format: "%.1f", elapsed))s，总计发现 \(discovered.count) 台设备\(discovered.isEmpty ? "" : " [\(names)]")")
        scanStartedAt = nil
    }

    // MARK: - 连接控制
    /// 发起连接：可在 UI 中选中某个 deviceId 后调用。设备连接与断开 (connect / disconnect)。提供方法来连接到指定的设备（通过设备 ID）。
    /// 管理连接状态（正在连接、已连接），同样通过 @Published 属性 (connectingId, connectedId) 反馈给 UI。
    /// 设备成功连接后，它会自动调用 startHr 方法开始接收心率数据。当设备断开连接后，它会自动停止数据流。
    func connect(id: String) {
        // 连接前停止扫描并记录日志
        if isScanning { stopScan() }
        do {
            try api.connectToDevice(id)
            connectingId = id
            log("CONNECT", "发起连接: \(id)")
        } catch {
            connectingId = nil
            log("CONNECT", "连接发起失败: \(error)")
        }
    }

    /// 主动断开连接
    func disconnect(id: String) {
        do {
            try api.disconnectFromDevice(id)
        } catch {
            print("[DISCONNECT][ERROR] \(error)")
        }
    }

    // MARK: - HR（心率）流订阅
    /// 开始订阅 HR 流（Polar 6.5：通过流 API 获取 HR 与 RR）。代码调用了 api.startHrStreaming，这个函数订阅的是 心率（HR）和 RR 间期（R-R Interval） 的数据流。
    /// 心率 (HR): lastHr 属性会实时更新为设备传来的一批数据中最新的心率值（单位是 BPM，每分钟心跳次数）。
    /// RR 间期 (RRi): 这是连续两次心跳（R波）之间的时间间隔，单位是毫秒（ms）。代码会获取到每一批数据中所有的 RR 间期值。
    /// 数据发送: 代码在收到数据后，会通过一个名为 UDPSenderService 的服务，将 HR 和 RR 数据打包成 JSON 格式，并通过 UDP 协议发送出去。这通常用于将数据实时传输到另一台设备或服务器进行分析。
    func startHr(id: String) {
        // 重启前清理旧订阅，避免重复回调
        hrDisposable?.dispose()
        hrDisposable = api
            .startHrStreaming(id)
            .observe(on: MainScheduler.instance) // 主线程更新 @Published 与发送 UDP
            .subscribe(
                onNext: { [weak self] hrBatch in
                    guard let self = self else { return }
                    let t = Date().timeIntervalSince1970

                    // 1) 以“本批最后一个样本”的 hr 作为“当前 HR”
                    if let s = hrBatch.last {
                        self.lastHr = s.hr
                        // 经 UDP 发送 HR（bpm）
                        UDPSenderService.shared.send(
                            #"{"type":"hr","bpm":\#(s.hr),"t_device":\#(t)}"#
                        )
                        // 1) 打印 HR，验证结果
                        print(String(format: "[H10][HR] %3d bpm  t=%.3f", s.hr, t))
                    }

                    // 2) 将本批所有 RR 间期（毫秒）展开发送为 IBI
                    //    注意：IBI（Inter-Beat Interval）是时域分析常用输入
                    for rr in hrBatch.flatMap({ $0.rrsMs }) {
                        self.lastRrMs.append(rr)  // 可按需保留最近窗口；此处累积举例
                        UDPSenderService.shared.send(
                            #"{"type":"ibi","ms":\#(rr),"t_device":\#(t)}"#
                        )
                        // 1) 打印 RR，验证结果
                        print(String(format: "[H10][IBI] %4d ms  t=%.3f", rr, t))
                    }
                },
                onError: { err in
                    print("[HR][ERROR] stream error: \(err)")
                }
            )
    }

    /// 停止订阅 HR 流
    func stopHr() {
        hrDisposable?.dispose()
        hrDisposable = nil
    }
}

// MARK: - 连接生命周期观察者
extension PolarManager: PolarBleApiObserver {

    /// 连接建立中（收到设备信息）
    func deviceConnecting(_ identifier: PolarDeviceInfo) {
        connectingId = identifier.deviceId
        print("[CONNECTING] \(identifier.deviceId)")
    }

    /// 连接已建立：记录连接目标、停止扫描、启动 HR 流
    func deviceConnected(_ identifier: PolarDeviceInfo) {
        connectedId = identifier.deviceId
        connectingId = nil
        stopScan()                               // 连接后立即停扫以稳定链路
        log("CONNECT", "已连接: \(identifier.deviceId)")
        startHr(id: identifier.deviceId)         // 启动 HR/RR 订阅
    }

    /// 已断开连接：复原状态并停止 HR 流
    func deviceDisconnected(_ identifier: PolarDeviceInfo, pairingError: Bool) {
        if connectedId == identifier.deviceId { connectedId = nil }
        connectingId = nil
        stopHr()
        log("CONNECT", "已断开: \(identifier.deviceId) pairingError=\(pairingError)")
    }
}

// MARK: - 蓝牙电源状态观察者（可用于提示用户开启蓝牙）
extension PolarManager: PolarBleApiPowerStateObserver {
    func blePowerOn()  { blePoweredOn = true;  print("[BLE] power ON") }
    func blePowerOff() { blePoweredOn = false; print("[BLE] power OFF") }
}

// MARK: - 设备信息观察者（电量、DIS 信息等；用于诊断与日志）
extension PolarManager: PolarBleApiDeviceInfoObserver {
    /// 电池电量（百分比）
    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        print("[DEVICE][BAT] \(identifier): \(batteryLevel)%")
    }

    /// 充电状态
    func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {
        print("[DEVICE][CHG] \(identifier): \(chargingStatus)")
    }

    /// 设备信息（Device Information Service, DIS）
    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        print("[DEVICE][DIS] \(identifier) \(uuid): \(value)")
    }

    /// DIS 的键值形式（部分固件以字符串键提供）
    func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        print("[DEVICE][DIS-KEY] \(identifier) \(key): \(value)")
    }
}

// MARK: - 设备特性就绪观察者（用于确认某功能可用）
extension PolarManager: PolarBleApiDeviceFeaturesObserver {
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        print("[FEATURE] ready @\(identifier): \(feature)")
    }
}
