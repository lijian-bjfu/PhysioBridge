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

/// 扫描、连接、订阅 HR/IBI 的集中管理器。
final class PolarManager: NSObject, ObservableObject {

    // MARK: - Singleton
    static let shared = PolarManager()

    // MARK: - 设备与网络状态（SwiftUI 订阅这些字段以更新界面）
    @Published var blePoweredOn: Bool = false          // BLE（低功耗蓝牙）是否开启
    @Published var isScanning: Bool = false            // 是否处于扫描状态
    @Published var discovered: [Discovered] = []       // 扫描到的设备列表
    @Published var connectingId: String? = nil         // 正在连接的 deviceId
    @Published var connectedId: String? = nil          // 已连接的 deviceId

    @Published var lastHr: UInt8 = 0                   // 最新心率（bpm）
    @Published var lastRrMs: [Int] = []                // 最新一批 RR 间期（毫秒），可映射为 IBI/PPI
    
    /// 扫描项：仅以 deviceId 作为身份标识；name/RSSI 为附属信息
    struct Discovered: Identifiable, Hashable {
        let id: String         // deviceId（唯一标识）
        let name: String
        let rssi: Int          // RSSI（信号强度）
        let connectable: Bool
        // Hash/Equal 默认即可，但在列表更新时我们仅按 id 去重
    }
    
    // 设备名占位
    private let h10 = TelemetrySpec.deviceNameH10
    private let verity = TelemetrySpec.deviceNameVerity
    
    // 动态选择“device 标签”，避免包头写死 H10
    private func deviceLabelForConnected() -> String {
        guard let id = connectedId,
              let dev = discovered.first(where: { $0.id == id }) else { return "Polar" }
        let n = dev.name.lowercased()
        if n.contains("sense") || n.contains("verity") { return verity }
        if n.contains("h10") { return h10 }
        return dev.name
    }
    
    // MARK: - 时间管理

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
    
    /// 扫描起始时间与心跳定时器
    private var scanStartedAt: Date?
    private var scanHeartbeatTimer: DispatchSourceTimer?
    

    // MARK: - Polar SDK
    private var api: PolarBleApi!                      // Polar 核心 API
    private let disposeBag = DisposeBag()              // 备用清理袋（当前主要使用手动 Disposable 字段）
    private var scanDisposable: Disposable?            // 扫描订阅
    
    // 统一管理“当前激活的流”
    private var activeStreams = Set<SignalKind>()


    // PPI streaming disposable 的订阅句柄
    private var ecgDisposable: Disposable?
    private var haccDisposable: Disposable?
    // H10 HR 包含了rr与hr
    private var hhrDisposable: Disposable?
    // HR/RR 共用一条 HR 流，通过两个布尔开关决定是否各自发送
    private var wantHR = false
    private var wantRR = false
    
    // 批次序号：用于 QA（检测丢批、重排）
    private var ecgSeq: UInt64 = 0
    private var accSeq: UInt64 = 0
    
    // Verity streaming disposable
    private var ppiDisposable: Disposable?
    private var vaccDisposable: Disposable?
    private var ppgDisposable: Disposable?
    
    /// verity ppi 定位日志
    private var ppiLoggedFirstSample = false
    
    /// 依据“AC-RMS 最小”优先判为 ambient；如有明显“符号相反”的单一路，也作为优先线索
    private func guessAmbientIndex(means: [Double], acRms: [Double]) -> Int? {
        guard means.count == acRms.count, !means.isEmpty else { return nil }
        // 1) 如果只有一个通道的均值符号与其他通道相反，优先选它
        let signs = means.map { $0 >= 0 ? 1 : -1 }
        for i in 0..<signs.count {
            let others = signs.enumerated().filter { $0.offset != i }.map { $0.element }
            if others.allSatisfy({ $0 == 1 }) && signs[i] == -1 { return i }
            if others.allSatisfy({ $0 == -1 }) && signs[i] == 1 { return i }
        }
        // 2) 否则选 AC-RMS 最小的（最不“随心跳起伏”的通常是 ambient）
        if let idx = acRms.enumerated().min(by: { $0.element < $1.element })?.offset {
            return idx
        }
        return nil
    }
    
    // MARK: - 信号发送小助手
    // 每个流的序号计数器
    private var seqHR:  UInt64 = 0
    private var seqRR:  UInt64 = 0
    private var seqECG: UInt64 = 0
    private var seqHACC: UInt64 = 0
    private var seqPPI: UInt64 = 0
    private var seqPPG: UInt64 = 0
    private var seqVACC: UInt64 = 0
    // 保存ppg的采样率
    private var ppgFsSelected: Int = 0

    // 统一的 JSON 发送助手
    private func sendPacket<T: Encodable>(_ packet: T) {
        if let json = TelemetryEncoder.encodeToJSONString(packet) {
            UDPSenderService.shared.send(json)
        }
    }

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

    // TODO: 是否还要清理别的？
    deinit {
        // 清理可能的订阅，避免泄漏
        scanDisposable?.dispose()
        hhrDisposable?.dispose()
    }

    // MARK: - 扫描sh（仅按名称前缀过滤；UI 层展示列表以供选择）
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

        // 启动 Polar SDK 扫描
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
    // MARK: - Streaming orchestration (所选即采)

    /// 根据研究者的选择集合，启动或停止对应数据流。applySelection 是统一入口：外部只需要传入“当前选中的信号集合”，就能完成差分启停
    /// - Parameters:
    ///   - deviceId: 已连接的设备 ID
    ///   - kinds: 研究者在 UI 中勾选的信号集合（SignalKind）
    @MainActor
    func applySelection(deviceId: String, kinds: Set<SignalKind>) {
        // 计算差分
        let toStart = kinds.subtracting(activeStreams)
        let toStop  = activeStreams.subtracting(kinds)

        // 先停后启，避免同一流先开后关的抖动
        for k in toStop { stop(kind: k) }
        for k in toStart { start(kind: k, deviceId: deviceId) }

        // HR/RR 共用一条底层 HR 订阅，通过开关决定是否发送
        // 如果两者都不需要了，主动停掉 HR 订阅；如果其中一个需要，确保 HR 订阅存在
        let needHRStream = kinds.contains(.hhr) || kinds.contains(.vhr) || kinds.contains(.rr)
        if !needHRStream {
            stopHr()            // 没人需要就停订阅
            wantHR = false
            wantRR = false
        } else {
            ensureHrStream(id: deviceId)
            wantHR = kinds.contains(.hhr) || kinds.contains(.vhr)
            wantRR = kinds.contains(.rr)
        }

        activeStreams = kinds
        log("STREAM", "applySelection -> \(kinds.map{$0.title}.sorted().joined(separator: ","))")
    }

    /// 停止所有已激活的数据流
    @MainActor
    func stopAllStreams() {
        stopHr()
        ecgDisposable?.dispose(); ecgDisposable = nil
        haccDisposable?.dispose(); haccDisposable = nil
        vaccDisposable?.dispose(); vaccDisposable = nil
        ppiDisposable?.dispose();  ppiDisposable  = nil
        ppgDisposable?.dispose();  ppgDisposable  = nil
        
        activeStreams.removeAll()
        wantHR = false
        wantRR = false
        log("STREAM", "stopAllStreams")
    }
    
    // MARK: - Settings probing for ECG/ACC

    /// 把 PolarSensorSetting 的内容展开为可读字符串，便于打印核对。该函数用于判断设备是否支持期望采集精度。
    private func describeSettings(_ settings: PolarSensorSetting) -> String {
        // 不同 SDK 版本字段名可能略有差异，这里尽量做健壮遍历
        var parts: [String] = []

        // 尝试常见键：sampleRate / resolution / range / channels 等
        if let sr = settings.settings[.sampleRate] {
            parts.append("sampleRate=\(Array(sr).sorted())")
        }
        if let rg = settings.settings[.range] {
            parts.append("range=\(Array(rg).sorted())")
        }
        if let rs = settings.settings[.resolution] {
            parts.append("resolution=\(Array(rs).sorted())")
        }
        if let ch = settings.settings[.channels] {
            parts.append("channels=\(Array(ch).sorted())")
        }

        // 兜底：打印所有键值，便于我们看到未覆盖到的字段
        if parts.isEmpty {
            let all = settings.settings.map { key, val in
                "\(key)=\(Array(val).sorted())"
            }.joined(separator: ", ")
            return all.isEmpty ? "<empty>" : all
        }
        return parts.joined(separator: ", ")
    }

    /// 探测 ECG 可用设置（不启动流）
    func probeEcgSettings(id: String) {
        api.requestStreamSettings(id, feature: .ecg)
            .asObservable()                               // ← 将 Single 转为 Observable
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] settings in   // ← onNext/设置项类型可推断
                guard let self = self else { return }
                let desc = self.describeSettings(settings)
                self.log("ECG", "available settings: \(desc)")
                // 期望：ECG 采样率包含 130 Hz
                self.log("ECG", "MVP default target: fs=130 Hz")
            }, onError: { [weak self] err in
                self?.log("ECG", "requestStreamSettings failed: \(err)")
            })
            .disposed(by: disposeBag)
    }
    /// 探测 ACC 可用设置（不启动流）
    func probeAccSettings(id: String) {
        api.requestStreamSettings(id, feature: .acc)
            .asObservable()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] settings in
                guard let self = self else { return }
                let desc = self.describeSettings(settings)
                self.log("ACC", "available settings: \(desc)")
                // 期望：ACC 采样率包含 25/50/100/200 Hz，量程包含 2/4/8 G
                self.log("ACC", "MVP default target: fs=50 Hz, range=±4G")
            }, onError: { [weak self] err in
                self?.log("ACC", "requestStreamSettings failed: \(err)")
            })
            .disposed(by: disposeBag)
    }
// MARK: - 订阅SignalKind中的所有数据
    /// 启动指定信号（除 HR/RR 外，HR/RR 在 ensureHrStream 统一处理）
    private func start(kind: SignalKind, deviceId: String) {
        let dev = self.deviceLabelForConnected()
        
        switch kind {
        case .vhr, .hhr, .rr:
            // HR/RR 的底层订阅由 ensureHrStream 统一处理；这里只设置开关由 applySelection 完成
            break
        case .ecg:
            // 若已有订阅先停止，避免重复回调
            ecgDisposable?.dispose()
            ecgDisposable = api
                .requestStreamSettings(deviceId, feature: .ecg)
                .asObservable() // Single -> Observable，便于统一 subscribe(onNext:onError:)
                .flatMap { [weak self] settings -> Observable<PolarEcgData> in
                    guard let self = self else { return .empty() }

                    // 从 settings.settings 中挑选采样率与分辨率
                    // 你的探测结果显示 sampleRate=[130], resolution=[14]
                    let srSet: Set<UInt32> = settings.settings[.sampleRate] ?? []
                    let rsSet: Set<UInt32> = settings.settings[.resolution] ?? []

                    // 首选 130Hz；如果设备不支持，则取集合中的最小可用值兜底
                    let srChosen: UInt32 = srSet.contains(130) ? 130 : (srSet.sorted().first ?? 130)
                    // 分辨率优先取 14；不支持则取集合中的最小可用值兜底
                    let rsChosen: UInt32 = rsSet.contains(14) ? 14 : (rsSet.sorted().first ?? 14)

                    // PolarSensorSetting 构造函数接收 [SettingType: UInt32]，值是“单个”UInt32
                    var dict: [PolarSensorSetting.SettingType: UInt32] = [
                        .sampleRate: srChosen
                    ]
                    // 分辨率在设备上有返回（resolution=[14]），加入即可；若以后没有该键也能正常工作
                    if !(rsSet.isEmpty) {
                        dict[.resolution] = rsChosen
                    }
                    let chosen = PolarSensorSetting(dict)

                    self.log("ECG", "start with settings: sampleRate=\(srChosen)\(dict[.resolution] != nil ? ", resolution=\(rsChosen)" : "")")
                    return self.api.startEcgStreaming(deviceId, settings: chosen)
                }
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] ecg in
                    guard let self = self else { return }
                    if !self.activeStreams.contains(.ecg) { return }
                    
                    let t = Date().timeIntervalSince1970

                    let fs = 130
                    // PolarEcgData 在 6.5.0 是数组 [(timeStamp, voltage)]
                    let uV: [Int] = ecg.map { Int($0.voltage) }
                    
                    // 仅当仍选择了 ECG 时才外发
                    if self.activeStreams.contains(.ecg) {
                        self.seqECG &+= 1
                        let pkt = ECGPacket(device: dev,
                                            t_device: t,
                                            seq: self.seqECG,
                                            fs: fs,
                                            uV: uV,
                                            n: uV.count)
                        self.sendPacket(pkt)
                        if let first = uV.first, let last = uV.last {
                            self.log("ECG", "batch n=\(uV.count) uV[\(first)...\(last)]")
                        } else {
                            self.log("ECG", "batch n=\(uV.count)")
                        }
                        Task { @MainActor in AppStore.shared.markSent() }
                    }
                }, onError: { [weak self] err in
                    self?.log("ECG", "stream error: \(err)")
                })

            log("STREAM", "ECG started (fs=130Hz)")
        case .hacc:
            // 若已有订阅先停止，避免重复回调
            haccDisposable?.dispose()
            // 1) 先查询 ACC 可用设置，再用所选设置开启流
            haccDisposable = api
                .requestStreamSettings(deviceId, feature: .acc)
                .asObservable()
                .flatMap { [weak self] settings -> Observable<PolarAccData> in
                    guard let self = self else { return .empty() }

                    // 从 settings.settings 中挑选采样率与量程
                    // 你的探测：sampleRate=[25,50,100,200], range=[2,4,8]
                    let srSet: [UInt32] = Array(settings.settings[.sampleRate] ?? []).sorted()
                    let rgSet: [UInt32] = Array(settings.settings[.range] ?? []).sorted()

                    // 目标优先 50Hz、±4G；不可用时兜底为集合中的最小可用值
                    let srChosen: UInt32 = srSet.contains(50) ? 50 : (srSet.first ?? 50)
                    let rgChosen: UInt32 = rgSet.contains(4)  ? 4  : (rgSet.first ?? 4)

                    var dict: [PolarSensorSetting.SettingType: UInt32] = [
                        .sampleRate: srChosen,
                        .range: rgChosen
                    ]
                    // 分辨率可选（你的设备返回 resolution=[16]），添加与否均可
                    if let rsSet = settings.settings[.resolution], let rsChosen = Array(rsSet).sorted().first {
                        dict[.resolution] = rsChosen
                    }
                    let chosen = PolarSensorSetting(dict)

                    self.log("ACC", "start with settings: sampleRate=\(srChosen), range=±\(rgChosen)G\(dict[.resolution] != nil ? ", resolution=\(dict[.resolution]!)" : "")")

                    // 2) 用选择的设置启动 ACC 流
                    return self.api.startAccStreaming(deviceId, settings: chosen)
                }
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] acc in
                    guard let self = self else { return }
                    if !self.activeStreams.contains(.hacc) { return }
                    
                    let t = Date().timeIntervalSince1970

                    // PolarAccData 在 6.5.0 是数组 [(timeStamp, x, y, z)]
                    // 将一批样本转为 [[x,y,z], ...]（单位：mG）
                    let triples: [[Int]] = acc.map { s in [Int(s.x), Int(s.y), Int(s.z)] }

                    // 仅当仍选择了 ACC 时才外发
                    if self.activeStreams.contains(.hacc) {
                        self.seqHACC &+= 1
                        // fs、range_g 请用你前面选择到的值；若已有变量，直接代入
                        let fs = 50
                        let rangeG = 4
                        let pkt = ACCPacket(device: dev,
                                            t_device: t,
                                            seq: self.seqHACC,
                                            fs: fs,
                                            mG: triples,
                                            n: triples.count,
                                            range_g: rangeG)
                        self.sendPacket(pkt)
                        if let first = triples.first, let last = triples.last {
                            self.log("ACC", "batch n=\(triples.count) mG[\(first) ... \(last)]")
                        } else {
                            self.log("ACC", "batch n=\(triples.count)")
                        }
                        Task { @MainActor in AppStore.shared.markSent() }
                    }
                }, onError: { [weak self] err in
                    self?.log("ACC", "stream error: \(err)")
                })

            log("STREAM", "ACC started (fs=50Hz, range=±4G)")
        case .vacc:
                vaccDisposable?.dispose()
                vaccDisposable = api
                    .requestStreamSettings(deviceId, feature: .acc)
                    .asObservable()
                    .flatMap { [weak self] settings -> Observable<PolarAccData> in
                        guard let self = self else { return .empty() }
                        // Verity 默认 52Hz, ±8G；若不可用，仍按你 MVP 的 50/4 兜底
                        let srSet = Array(settings.settings[.sampleRate] ?? []).sorted()
                        let rgSet = Array(settings.settings[.range] ?? []).sorted()
                        let srChosen: UInt32 = srSet.contains(52) ? 52 : (srSet.contains(50) ? 50 : (srSet.first ?? 50))
                        let rgChosen: UInt32 = rgSet.contains(8)  ? 8  : (rgSet.contains(4) ? 4 : (rgSet.first ?? 4))
                        var dict: [PolarSensorSetting.SettingType: UInt32] = [
                            .sampleRate: srChosen,
                            .range: rgChosen,
                            .channels: 3        // ← Verity ACC 固定三轴，必须显式传 3
                        ]
                        if let rsSet = settings.settings[.resolution], let rs = Array(rsSet).sorted().first {
                            dict[.resolution] = rs
                        }
                        let chosen = PolarSensorSetting(dict)
                        self.log("ACC", "Verity start with settings: fs=\(srChosen), range=±\(rgChosen)G\(dict[.resolution] != nil ? ", res=\(dict[.resolution]!)" : "")")
                        return self.api.startAccStreaming(deviceId, settings: chosen)
                    }
                    .observe(on: MainScheduler.instance)
                    .subscribe(onNext: { [weak self] acc in
                        guard let self = self else { return }
                        if !self.activeStreams.contains(.vacc) { return }
                        let t = Date().timeIntervalSince1970
                        let triples: [[Int]] = acc.map { s in [Int(s.x), Int(s.y), Int(s.z)] }
                        self.seqVACC &+= 1
                        let pkt = ACCPacket(device: dev,
                                            t_device: t, seq: self.seqVACC,
                                            fs: 52, mG: triples, n: triples.count, range_g: 8)
                        self.sendPacket(pkt)
                        Task { @MainActor in AppStore.shared.markSent() }
                    }, onError: { [weak self] err in
                        self?.log("ACC", "Verity stream error: \(err)")
                    })
                log("STREAM", "ACC started (Verity, fs≈52Hz, range=±8G)")

        case .ppi:
                ppiDisposable?.dispose()
                ppiDisposable = api
                    .startPpiStreaming(deviceId)
                    .observe(on: MainScheduler.instance)
                    .subscribe(onNext: { [weak self] ppi in
                        guard let self = self else { return }
                        if !self.activeStreams.contains(.ppi) { return }
                        // PolarPpiData 通常是数组，含 ppInMs 与误差估计
                        let t = Date().timeIntervalSince1970
                        for s in ppi.samples {
                            self.seqPPI &+= 1
                            let pkt = PPIPacket(device: dev, t_device: t, seq: self.seqPPI, ms: Int(s.ppInMs), quality: Int(s.ppErrorEstimate))
                            self.sendPacket(pkt)
                        }
                        Task { @MainActor in AppStore.shared.markSent() }
                    }, onError: { [weak self] err in
                        self?.log("PPI", "stream error: \(err)")
                    })
                log("STREAM", "PPI started")

        case .ppg:
            // 先停已有订阅，避免重复回调
            ppgDisposable?.dispose()
            ppgDisposable = api
                .requestStreamSettings(deviceId, feature: .ppg)
                .asObservable()
                .flatMap { [weak self] settings -> Observable<PolarPpgData> in
                    guard let self = self else { return .empty() }
                    
                    self.log("PPG", "available settings: \(self.describeSettings(settings))")


                    // 挑选采样率/分辨率/通道数：优先 135 Hz / 22 bit / 4 ch
                    let srSet: Set<UInt32> = settings.settings[.sampleRate] ?? []
                    let rsSet: Set<UInt32> = settings.settings[.resolution] ?? []
                    let chSet: Set<UInt32> = settings.settings[.channels] ?? []

                    let srChosen: UInt32 = srSet.contains(135) ? 135 : (srSet.sorted().first ?? (srSet.first ?? 135))
                    let rsChosen: UInt32 = rsSet.contains(22)  ? 22  : (rsSet.sorted().first ?? (rsSet.first ?? 22))
                    let chChosen: UInt32 = chSet.contains(4)   ? 4   : (chSet.sorted().last ?? (chSet.first ?? 1))

                    let chosen = PolarSensorSetting([
                        .sampleRate: srChosen,
                        .resolution: rsChosen,
                        .channels:   chChosen
                    ])
                    
                    self.ppgFsSelected = Int(srChosen)
                    
                    self.log("PPG", "start with settings: fs=\(srChosen)Hz, res=\(rsChosen)bit, channels=\(chChosen)")
                    return self.api.startPpgStreaming(deviceId, settings: chosen)
                }
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] ppg in
                    guard let self = self else { return }
                    if !self.activeStreams.contains(.ppg) { return }

                    // PolarPpgData: 批结构，每个 sample 内含多通道强度
                    self.seqPPG &+= 1
                    let t = Date().timeIntervalSince1970
                    let n = ppg.samples.count
                    let ch = ppg.samples.first?.channelSamples.count ?? 0
                    let matrix = ppg.samples.map { $0.channelSamples.map(Int.init) }

                    let pkt = PPGPacket(
                        device: dev,
                        t_device: t,
                        seq: self.seqPPG,
                        fs: self.ppgFsSelected,
                        n: n,
                        ch: ch,
                        mU: matrix
                    )
                    self.sendPacket(pkt)
                    self.log("PPG", "batch n=\(n) channels=\(ch)")
                    Task { @MainActor in AppStore.shared.markSent() }

                    // 先只确认流稳定与通道数正确；UDP 打包下一步再加
                }, onError: { [weak self] err in
                    self?.log("PPG", "stream error: \(err)")
                })
            log("STREAM", "PPG started (Verity)")
                break
            }
    }

    /// 停止指定信号（HR/RR 走 stopHr；其余各自 dispose）
    private func stop(kind: SignalKind) {
        switch kind {
        case .hhr, .vhr, .rr:
            // HR/RR 是否真正停由 applySelection 统一判定
            break
        case .ecg:
            ecgDisposable?.dispose(); ecgDisposable = nil
            log("STREAM", "ECG stopped")
        case .hacc:
            haccDisposable?.dispose(); haccDisposable = nil
            log("STREAM", "ACC stopped (H10)")
        case .vacc:
            vaccDisposable?.dispose(); vaccDisposable = nil
            log("STREAM", "ACC stopped (Verity)")
        case .ppi:
            ppiDisposable?.dispose();  ppiDisposable  = nil
            log("STREAM", "PPI stopped")
        case .ppg:
            ppgDisposable?.dispose();  ppgDisposable  = nil
            log("STREAM", "PPG stopped")
        }
    }

    // MARK: - 订阅 H10的 HR，RR
    /// 开始订阅 HR 流（Polar 6.5：通过流 API 获取 HR 与 RR）。代码调用了 api.startHrStreaming，这个函数订阅的是 心率（HR）和 RR 间期（R-R Interval） 的数据流。
    /// 心率 (HR): lastHr 属性会实时更新为设备传来的一批数据中最新的心率值（单位是 BPM，每分钟心跳次数）。
    /// RR 间期 (RRi): 这是连续两次心跳（R波）之间的时间间隔，单位是毫秒（ms）。代码会获取到每一批数据中所有的 RR 间期值。
    /// 数据发送: 代码在收到数据后，会通过 UDPSenderService 的服务，将 HR 和 RR 数据打包成 JSON 格式，并通过 UDP 协议发送出去。这通常用于将数据实时传输到另一台设备或服务器进行分析。
    func startHr(id: String) {
        // 重启前清理旧订阅，避免重复回调
        hhrDisposable?.dispose()
        hhrDisposable = api
            .startHrStreaming(id)
            .observe(on: MainScheduler.instance) // 主线程更新 @Published 与发送 UDP
            .subscribe(
                onNext: { [weak self] hrBatch in
                    guard let self = self else { return }
                    let t = Date().timeIntervalSince1970
                    let dev = self.deviceLabelForConnected()

                    // 1) 以“本批最后一个样本”的 hr 作为“当前 HR”
                    // 仅当用户选择了hr数据时才发
                    if let s = hrBatch.last, wantHR {
                        self.lastHr = s.hr
                        self.seqHR &+= 1
                        let p = HRPacket(device: dev, t_device: t, seq: self.seqHR, bpm: Int(s.hr))
                        self.sendPacket(p)
                        Task { @MainActor in AppStore.shared.markSent() }
                    }
                    // 2) 将本批所有 RR 间期（毫秒）展开发送为 IBI
                    // 仅当用户选择了rr数据才发
                    if wantRR {
                        for rr in hrBatch.flatMap({ $0.rrsMs }) {
                            self.lastRrMs.append(rr)
                            self.seqRR &+= 1
                            let prr = RRPacket(device: dev, t_device: t, seq: self.seqRR, ms: rr)
                            self.sendPacket(prr)
                            print("[UDP][RR] ms=\(rr)")
                            Task { @MainActor in AppStore.shared.markSent() }
                        }
                    }
                },
                onError: { err in
                    print("[HR][ERROR] stream error: \(err)")
                }
            )
    }

    /// 停止订阅 HR 流
    func stopHr() {
        hhrDisposable?.dispose()
        hhrDisposable = nil
    }
    
    /// 若需要 HR/RR 中任一，则确保底层 HR 订阅已建立
    private func ensureHrStream(id: String) {
        if hhrDisposable != nil { return }
        startHr(id: id)
    }
    
    // MARK: - 订阅 Verity Sense 的PPI, PPG, VHR, VACC
    // TODO: 实现Verity 数据的订阅
    func startVerityData(deviceId: String, deviceLabel: String = "Verity") {

    }

    /// 停止订阅 PPI
    func stopPpi() {
        ppiDisposable?.dispose()
        ppiDisposable = nil
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
        log("CONNECT", "等待采集页选择后再订阅数据流")
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
