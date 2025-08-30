//
//  PolarManager.swift
//  PolarBridge
//
//  Created by lijian on 8/27/25.
//

//
//  PolarManager.swift
//  职责：扫描/连接两台 Polar（H10 与 Verity），并行管理各自的流订阅；
//       将 HR/RR/ECG/ACC/PPG/PPI 以 JSON 通过 UDP 发送；
//       通过 @Published 曝光 UI 所需状态。
//  依赖：PolarBleSdk 6.5.x, RxSwift
//

import Foundation
import CoreBluetooth
import PolarBleSdk
import RxSwift

final class PolarManager: NSObject, ObservableObject {

    // MARK: - Singleton
    static let shared = PolarManager()

    // MARK: - UI 可观察状态
    @Published var blePoweredOn: Bool = false
    @Published var isScanning: Bool = false

    @Published var discovered: [Discovered] = []

    /// 仅用于 UI 显示“正在连接”的图标，可能在两个设备之间切换
    @Published var connectingId: String? = nil

    /// 独立记录两台设备的连接成功 ID，避免相互覆盖
    @Published var connectedH10Id: String? = nil
    @Published var connectedVerityId: String? = nil

    /// 最近一次心率/rr 样本（便于 DebugView）
    @Published var lastHr: UInt8 = 0
    @Published var lastRrMs: [Int] = []

    struct Discovered: Identifiable, Hashable {
        let id: String
        let name: String
        let rssi: Int
        let connectable: Bool
        var batteryLevel: Int? = nil
    }

    // MARK: - 内部状态：每设备所选/所启流
    /// 研究者“勾选”的集合（每台设备一份）
    private var selectedKindsByDevice: [String: Set<SignalKind>] = [:]
    /// 真正“已启”的集合（每台设备一份）
    private var activeStreamsByDevice: [String: Set<SignalKind>] = [:]

    // MARK: - Polar SDK 与订阅句柄
    private var api: PolarBleApi!
    private var batteryTimers: [String: DispatchSourceTimer] = [:]

    private var scanDisposable: Disposable?

    /// HR/RR 订阅句柄：每台设备一份
    private var hrDisposableById: [String: Disposable] = [:]

    /// H10 侧：ECG/HACC
    private var ecgDisposable:  Disposable?
    private var haccDisposable:  Disposable?

    /// Verity 侧：PPG/VACC/PPI
    private var ppgDisposable:   Disposable?
    private var vaccDisposable:  Disposable?
    private var ppiDisposable:   Disposable?

    // 批次递增序号（便于 QA）
    private var seqHR:  UInt64 = 0
    private var seqRR:  UInt64 = 0
    private var seqECG: UInt64 = 0
    private var seqHACC: UInt64 = 0
    private var seqPPG: UInt64 = 0
    private var seqVACC: UInt64 = 0
    private var seqPPI: UInt64 = 0

    // PPG fs 记录（选择后缓存）
    private var ppgFsSelected: Int = 0

    // 扫描心跳
    private var scanStartedAt: Date?
    
    // 用于UI信号流打印
    @Published var lastECGuV: Int? = nil      // ECG 最近一个 uV
    @Published var lastPPG1: Int? = nil       // PPG ch1 最近一个 a.u.
    @Published var lastPpiMs: Int? = nil      // PPI 最近一个 ms

    // MARK: - 常量
    private let nameH10    = TelemetrySpec.deviceNameH10
    private let nameVerity = TelemetrySpec.deviceNameVerity

    // MARK: - 工具函数
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func log(_ tag: String, _ msg: String) {
        let ts = Self.iso8601.string(from: Date())
        print("\(ts) [\(tag)] \(msg)")
    }

    private func deviceLabel(for id: String) -> String {
        if let dev = discovered.first(where: { $0.id == id }) {
            let n = dev.name.lowercased()
            if n.contains("sense") || n.contains("verity") || n.contains("oh1") { return nameVerity }
            if n.contains("h10") { return nameH10 }
            return dev.name
        }
        return "Polar"
    }

    private func sendPacket<T: Encodable>(_ packet: T) {
        if let json = TelemetryEncoder.encodeToJSONString(packet) {
            UDPSenderService.shared.send(json)
        }
    }
    
    // MARK: - 丢包计算工具
    // 统计窗口：每台设备 × 每种连续流，对最近 60s 到达样本计数
    @Published private(set) var loss60sByDeviceAndKind: [String: [SignalKind: Double]] = [:]

    // 内部状态：滑窗点列与当前 fs
    private struct LossWindow {
        var fs: Int                // 当前生效的采样率
        var points: [(t: Double, n: Int)] = []  // 批次到达时间与样本数
        mutating func record(now: Double, n: Int, fs: Int) {
            self.fs = fs
            points.append((now, n))
            prune(now: now)
        }
        mutating func prune(now: Double) {
            let floor = now - 60.0
            while let first = points.first, first.t < floor { points.removeFirst() }
        }
        func loss(now: Double) -> Double? {
            guard let first = points.first, fs > 0 else { return nil }
            let elapsed = min(60.0, now - first.t)
            guard elapsed > 0 else { return nil }
            let arrived = points.reduce(0) { $0 + $1.n }
            let expected = Double(fs) * elapsed
            guard expected > 0 else { return nil }
            let rate = max(0, 1 - Double(arrived)/expected)
            return min(1, rate)
        }
    }
    private var lossWindows: [String: LossWindow] = [:]
    private func lwKey(_ id: String, _ kind: SignalKind) -> String { "\(id)|\(kind.rawValue)" }
    private func recordLoss(deviceId: String, kind: SignalKind, samples n: Int, fs: Int) {
        let now = Date().timeIntervalSince1970
        let k = lwKey(deviceId, kind)
        var w = lossWindows[k] ?? LossWindow(fs: fs, points: [])
        w.record(now: now, n: n, fs: fs)
        lossWindows[k] = w
        if let rate = w.loss(now: now) {
            var byKind = loss60sByDeviceAndKind[deviceId] ?? [:]
            byKind[kind] = rate
            loss60sByDeviceAndKind[deviceId] = byKind
        }
    }


    // MARK: - 初始化
    override init() {
        super.init()
        api = PolarBleApiDefaultImpl.polarImplementation(
            .main,
            features: [
                .feature_hr,
                .feature_device_info,
                .feature_battery_info,
                .feature_polar_online_streaming
            ]
        )
        api.observer = self
        api.powerStateObserver = self
        api.deviceInfoObserver = self
        api.deviceFeaturesObserver = self
    }

    deinit {
        scanDisposable?.dispose()
        stopHrAll()
        ecgDisposable?.dispose()
        haccDisposable?.dispose()
        ppgDisposable?.dispose()
        vaccDisposable?.dispose()
        ppiDisposable?.dispose()
    }

    // MARK: - 扫描
    func startScan(prefix: String? = "Polar") {
        guard scanDisposable == nil else { return }
        isScanning = true
        scanStartedAt = Date()
        log("SCAN", "开始扫描 prefix=\(prefix ?? "nil")")

        scanDisposable = api
            .searchForDevice(withRequiredDeviceNamePrefix: prefix)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] info in
                guard let self = self else { return }
                
                let incoming = Discovered(id: info.deviceId, name: info.name, rssi: info.rssi, connectable: info.connectable)
                
                if let idx = self.discovered.firstIndex(where: { $0.id == incoming.id }) {
                    // 保留旧电量，避免被置空
                    let prev = self.discovered[idx]
                    
                    self.discovered[idx] = Discovered(
                        id: incoming.id,
                        name: incoming.name,
                        rssi: incoming.rssi,
                        connectable: incoming.connectable,
                        batteryLevel: prev.batteryLevel
                    )
                    
                    // 检查rssi的信号质量变化
                    let rssiDelta = incoming.rssi - prev.rssi
                    self.log("DISCOVERY",
                             "更新设备: id=\(incoming.id) name=\(incoming.name) rssi \(prev.rssi)→\(incoming.rssi) (\(rssiDelta >= 0 ? "+" : "")\(rssiDelta)) connectable=\(incoming.connectable)")
                    
                } else {
                    self.discovered.append(incoming)
                    self.log("DISCOVERY",
                             "发现设备: id=\(info.deviceId) name=\(info.name) rssi=\(info.rssi) connectable=\(info.connectable)")
                }
            }, onError: { [weak self] err in
                self?.isScanning = false
                self?.scanDisposable = nil
                self?.log("SCAN", "扫描失败: \(err)")
            })
    }

    func stopScan() {
        scanDisposable?.dispose(); scanDisposable = nil
        isScanning = false

        let elapsed = scanStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let names = discovered.map { "\($0.name)#\($0.id.prefix(4))" }.joined(separator: ", ")
        log("SCAN", "结束。时长=\(String(format: "%.1f", elapsed))s，总计发现 \(discovered.count) 台设备\(names.isEmpty ? "" : " [\(names)]")")
        scanStartedAt = nil
    }

    // MARK: - 连接控制
    func connect(id: String) {
        if isScanning { stopScan() }
        do {
            connectingId = id
            try api.connectToDevice(id)
            log("CONNECT", "发起连接: \(id)")
        } catch {
            connectingId = nil
            log("CONNECT", "连接发起失败: \(error)")
        }
    }

    func disconnect(id: String) {
        // 主动断开；Polar SDK 会回调 deviceDisconnected
        do {
            try api.disconnectFromDevice(id)
        } catch {
            log("DISCONNECT", "主动断开失败: \(error)")
        }
    }

    // MARK: - 选择/启停编排（每台设备独立）
    @MainActor
    func applySelection(deviceId: String, kinds: Set<SignalKind>) {
        selectedKindsByDevice[deviceId] = kinds
        let was = activeStreamsByDevice[deviceId] ?? []
        // 差分只针对本设备
        let toStop  = was.subtracting(kinds)
        let toStart = kinds.subtracting(was)

        // 先停再启，避免抖动
        for k in toStop  { stop(kind: k, deviceId: deviceId) }
        for k in toStart { start(kind: k, deviceId: deviceId) }

        // HR/RR 底层订阅：只要本设备勾选了 HR 或 RR，就确保存在
        let needHR = kinds.contains(.hhr) || kinds.contains(.vhr) || kinds.contains(.rr) || kinds.contains(.ppi)
        if needHR { ensureHrStream(id: deviceId) } else { stopHr(id: deviceId) }

        activeStreamsByDevice[deviceId] = kinds
        log("STREAM", "applySelection[\(deviceId.prefix(4))] -> \(kinds.map{$0.title}.sorted().joined(separator: ","))")
    }

    @MainActor
    func stopAllStreams() {
        stopHrAll()
        ecgDisposable?.dispose();  ecgDisposable  = nil
        haccDisposable?.dispose(); haccDisposable = nil
        ppgDisposable?.dispose();  ppgDisposable  = nil
        vaccDisposable?.dispose(); vaccDisposable = nil
        ppiDisposable?.dispose();  ppiDisposable  = nil

        activeStreamsByDevice.removeAll()
        log("STREAM", "stopAllStreams")
    }

    // MARK: - HR/RR（每设备一份）
    private func ensureHrStream(id: String) {
        if hrDisposableById[id] != nil { return }
        startHr(id: id)
    }

    private func startHr(id: String) {
        // 清旧 → 开新（每台设备）
        hrDisposableById[id]?.dispose()
        hrDisposableById[id] = api
            .startHrStreaming(id)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] batch in
                guard let self = self else { return }
                let tHost = Date().timeIntervalSince1970
                let devLabel = self.deviceLabel(for: id)
                let chosen = self.selectedKindsByDevice[id] ?? []

                // 1) HR：取末样本作为“当前 HR”
                if let s = batch.last, chosen.contains(.hhr) || chosen.contains(.vhr) {
                    self.lastHr = s.hr
                    self.seqHR &+= 1
                    let p = HRPacket(device: devLabel, t_device: tHost, seq: self.seqHR, bpm: Int(s.hr))
                    self.sendPacket(p)
                    self.log("HR", "\(devLabel) start bpm=\(s.hr)")
                    //Task { @MainActor in AppStore.shared.markSent() }
                }

                // 2) RR：展开每个间期成单事件
                if chosen.contains(.rr) {
                    let rrs = batch.flatMap { $0.rrsMs }
                    let events = BeatEventAligner.shared.alignRRBatch(deviceId: id, rrsMs: rrs, tHost: tHost)
                    for (rr, te) in zip(rrs, events) {
                        self.lastRrMs.append(rr)
                        self.seqRR &+= 1
                        let prr = RRPacket(device: devLabel, t_device: tHost, seq: self.seqRR, ms: rr, te: te)
                        self.sendPacket(prr)
                        self.log("RR", "\(devLabel) start")
                        //Task { @MainActor in AppStore.shared.markSent() }
                    }
                }
            }, onError: { [weak self] err in
                self?.log("HR", "stream error[\(id)]: \(err)")
            })
    }

    private func stopHr(id: String) {
        hrDisposableById[id]?.dispose()
        hrDisposableById[id] = nil
    }

    private func stopHrAll() {
        for (id, d) in hrDisposableById { d.dispose(); hrDisposableById[id] = nil }
        hrDisposableById.removeAll()
    }

    // MARK: - 具体信号启停（仅作用于传入 deviceId）
    private func start(kind: SignalKind, deviceId: String) {
        let dev = deviceLabel(for: deviceId)

        switch kind {

        case .hhr, .vhr, .rr:
            // 底层由 ensureHrStream 统一管理；这里无需直接开启
            return

        case .ecg: // H10 ECG
            ecgDisposable?.dispose()
            ecgDisposable = api
                .requestStreamSettings(deviceId, feature: .ecg)
                .asObservable()
                .flatMap { [weak self] settings -> Observable<PolarEcgData> in
                    guard let self = self else { return .empty() }
                    
                    let s = settings.settings
                    let srSet = Array(s[.sampleRate] ?? []).sorted()
                    let rsSet = Array(s[.resolution] ?? []).sorted()
                    // self.log("ECG", "H10 available settings: sr=\(srSet) res=\(rsSet)")
                    
                    let sr: UInt32 = srSet.contains(130) ? 130 : (srSet.first ?? 130)
                    let rs: UInt32 = rsSet.contains(14)  ? 14  : (rsSet.first ?? 14)
                    let chosen = PolarSensorSetting([.sampleRate: sr, .resolution: rs])
                    self.log("ECG", "start settings fs=\(sr)Hz res=\(rs)bit")
                    return self.api.startEcgStreaming(deviceId, settings: chosen)
                }
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] ecg in
                    guard let self = self else { return }
                    // 只看该设备的激活集
                    guard (self.activeStreamsByDevice[deviceId] ?? []).contains(.ecg) else { return }
                    self.seqECG &+= 1
                    let t = Date().timeIntervalSince1970
                    let uV = ecg.map { Int($0.voltage) }
                    let pkt = ECGPacket(device: dev, t_device: t, seq: self.seqECG, fs: 130, uV: uV, n: uV.count)
                    self.sendPacket(pkt)
                    self.log("ECG", "batch n=\(uV.count)")
                    
                    // 计算ecg丢包
                    self.recordLoss(deviceId: deviceId, kind: .ecg, samples: uV.count, fs: 130)
                    
                    // 记录ecg最新值用于UI打印
                    self.lastECGuV = uV.last
                    
                }, onError: { [weak self] err in
                    self?.log("ECG", "stream error[\(deviceId)]: \(err)")
                })
            log("STREAM", "ECG started (H10)")

        case .hacc: // H10 ACC
            // 若已有订阅先停止，避免重复回调
            haccDisposable?.dispose()
            // 丢包变量
            var selSr: UInt32 = 0
            // 先查询 ACC 可用设置，再用所选设置开启流
            haccDisposable = api
                .requestStreamSettings(deviceId, feature: .acc)
                .asObservable()
                .flatMap { [weak self] settings -> Observable<PolarAccData> in
                    guard let self = self else { return .empty() }
                    
                    // 从 settings.settings 中挑选采样率与量程
                    let s = settings.settings
                    let srSet = Array(s[.sampleRate] ?? []).sorted()
                    let rgSet = Array(s[.range] ?? []).sorted()
                    let rsSet = Array(s[.resolution] ?? []).sorted()
                    
                    self.log("ACC", "H10 available settings: sr=\(srSet) range=\(rgSet) res=\(rsSet)")
                    
                    // 目标优先 50Hz、±4G；不可用时兜底为集合中的最小可用值
                    // 如果 H10 实际没有 range 键，就不会把 .range 放进设置，避免无效参数
                    guard let sr = (srSet.contains(50) ? 50 : srSet.first) else {
                        self.log("ACC", "H10 no sampleRate available, abort")
                        return .empty()
                    }
                    selSr = sr
                    // 组装仅包含“设备确实支持”的键
                    var chosenDict: [PolarSensorSetting.SettingType: UInt32] = [.sampleRate: sr]
                    
                    if let rg = (rgSet.contains(4) ? 4 : rgSet.first) {
                        chosenDict[.range] = rg
                    }
                    if let rs = (rsSet.contains(16) ? 16 : rsSet.first) {
                        chosenDict[.resolution] = rs
                    }

                    let chosen = PolarSensorSetting(chosenDict)
                    let rgLog = chosenDict[.range].map { "±\($0)G" } ?? "n/a"
                    let rsLog = chosenDict[.resolution].map { "\($0)bit" } ?? "n/a"
                    self.log("ACC", "H10 start fs=\(sr)Hz \(rgLog) res=\(rsLog)")
                    return self.api.startAccStreaming(deviceId, settings: chosen)
                }
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] acc in
                    guard let self = self else { return }
                    guard (self.activeStreamsByDevice[deviceId] ?? []).contains(.hacc) else { return }
                    self.seqHACC &+= 1
                    let t = Date().timeIntervalSince1970
                    let triples = acc.map { [Int($0.x), Int($0.y), Int($0.z)] }
                    let pkt = ACCPacket(device: dev, t_device: t, seq: self.seqHACC, fs: 50, mG: triples, n: triples.count, range_g: 4)
                    self.sendPacket(pkt)
                    
                    // 丢包
                    let fsInt = selSr == 0 ? 50 : Int(selSr)
                    self.recordLoss(deviceId: deviceId, kind: .hacc, samples: triples.count, fs: fsInt)
                }, onError: { [weak self] err in
                    self?.log("ACC", "H10 stream error[\(deviceId)]: \(err)")
                })
            log("STREAM", "ACC started (H10, 50Hz, ±4G)")

        case .vacc: // Verity ACC
            // 1) 先清理旧订阅，避免重复回调
            vaccDisposable?.dispose()

            // 2) 用捕获变量保存 “所选参数”，供 subscribe/onNext 打包使用
            var selSr: UInt32 = 0
            var selRg: UInt32 = 0

            vaccDisposable = api
                .requestStreamSettings(deviceId, feature: .acc)
                .asObservable()
                .flatMap { [weak self] (settings: PolarSensorSetting) -> Observable<PolarAccData> in
                    guard let self = self else { return .empty() }

                    let s = settings.settings
                    let srSet = Array(s[.sampleRate] ?? []).sorted()
                    let rgSet = Array(s[.range] ?? []).sorted()
                    let rsSet = Array(s[.resolution] ?? []).sorted()
                    let chSet = Array(s[.channels] ?? []).sorted()

                    self.log("ACC", "Verity available: sr=\(srSet) range=\(rgSet) res=\(rsSet) ch=\(chSet)")

                    // 采样率优先 52Hz，其次 50Hz，再退集合首项
                    guard let sr = (srSet.contains(52) ? 52 : (srSet.contains(50) ? 50 : srSet.first)) else {
                        self.log("ACC", "Verity no sampleRate available, abort")
                        return .empty()
                    }
                    selSr = sr

                    // 仅写“设备确实暴露”的键，避免 GATT Invalid *
                    var chosen: [PolarSensorSetting.SettingType: UInt32] = [.sampleRate: sr]

                    if let rg = (rgSet.contains(8) ? 8 : (rgSet.contains(4) ? 4 : rgSet.first)) {
                        chosen[.range] = rg
                        selRg = rg
                    } else {
                        selRg = 0 // 兜底
                    }
                    if let rs = (rsSet.contains(16) ? 16 : rsSet.first) {
                        chosen[.resolution] = rs
                    }
                    if let ch = chSet.first {
                        // 只有设备暴露了 channels 才设置；很多固件不暴露这个键
                        chosen[.channels] = ch
                    }

                    let setting = PolarSensorSetting(chosen)
                    let rgLog = chosen[.range].map { "±\($0)G" } ?? "n/a"
                    let rsLog = chosen[.resolution].map { "\($0)bit" } ?? "n/a"
                    let chLog = chosen[.channels].map { "\($0)" } ?? "n/a"
                    self.log("ACC", "Verity start fs=\(sr)Hz \(rgLog) res=\(rsLog) ch=\(chLog)")

                    return self.api.startAccStreaming(deviceId, settings: setting)
                }
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] acc in
                    guard let self = self else { return }
                    guard (self.activeStreamsByDevice[deviceId] ?? []).contains(.vacc) else { return }

                    self.seqVACC &+= 1
                    let t = Date().timeIntervalSince1970
                    let triples = acc.map { [Int($0.x), Int($0.y), Int($0.z)] }

                    // 用“实际选中的” fs / range_g，避免与上游不一致
                    let fsInt = selSr == 0 ? 52 : Int(selSr)
                    let rangeInt = selRg == 0 ? 8 : Int(selRg)

                    let pkt = ACCPacket(
                        device: dev,
                        t_device: t,
                        seq: self.seqVACC,
                        fs: fsInt,
                        mG: triples,
                        n: triples.count,
                        range_g: rangeInt
                    )
                    self.sendPacket(pkt)
                    
                    // 丢包计算
                    self.recordLoss(deviceId: deviceId, kind: .vacc, samples: triples.count, fs: fsInt)
                }, onError: { [weak self] err in
                    self?.log("ACC", "Verity stream error[\(deviceId)]: \(err)")
                })
            log("STREAM", "ACC started (Verity, 52Hz, ±8G)")

        case .ppg: // Verity PPG
            ppgDisposable?.dispose()
            ppgDisposable = api
                .requestStreamSettings(deviceId, feature: .ppg)
                .asObservable()
                .flatMap { [weak self] settings -> Observable<PolarPpgData> in
                    guard let self = self else { return .empty() }
                    let srSet: Set<UInt32> = settings.settings[.sampleRate] ?? []
                    let rsSet: Set<UInt32> = settings.settings[.resolution] ?? []
                    let chSet: Set<UInt32> = settings.settings[.channels] ?? []
                    // Verity 常见 55Hz / 22bit / 4ch，若固件更新支持 135Hz 则优先
                    let sr: UInt32 = srSet.contains(135) ? 135 : (srSet.sorted().first ?? 55)
                    let rs: UInt32 = rsSet.contains(22)  ? 22  : (rsSet.sorted().first ?? 22)
                    let ch: UInt32 = chSet.contains(4)   ? 4   : (chSet.sorted().last ?? 4)
                    self.ppgFsSelected = Int(sr)
                    let chosen = PolarSensorSetting([.sampleRate: sr, .resolution: rs, .channels: ch])
                    self.log("PPG", "start settings fs=\(sr)Hz res=\(rs)bit ch=\(ch)")
                    return self.api.startPpgStreaming(deviceId, settings: chosen)
                }
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] ppg in
                    guard let self = self else { return }
                    guard (self.activeStreamsByDevice[deviceId] ?? []).contains(.ppg) else { return }
                    self.seqPPG &+= 1
                    let t = Date().timeIntervalSince1970
                    let n = ppg.samples.count
                    let ch = ppg.samples.first?.channelSamples.count ?? 0
                    let matrix = ppg.samples.map { $0.channelSamples.map(Int.init) }
                    let pkt = PPGPacket(device: dev, t_device: t, seq: self.seqPPG, fs: self.ppgFsSelected, n: n, ch: ch, mU: matrix)
                    self.sendPacket(pkt)
                    self.log("PPG", "batch n=\(n) channels=\(ch)")
                    
                    // 丢包
                    self.recordLoss(deviceId: deviceId, kind: .ppg, samples: n, fs: self.ppgFsSelected)
                    
                    // 记录最新ppg 第一通道
                    let ch1 = matrix.last?.first
                    self.lastPPG1 = ch1
                    
                }, onError: { [weak self] err in
                    self?.log("PPG", "stream error[\(deviceId)]: \(err)")
                })
            log("STREAM", "PPG started (Verity)")

        case .ppi: // Verity PPI（逐事件）
            ppiDisposable?.dispose()
            ppiDisposable = api
                .startPpiStreaming(deviceId)
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] ppi in
                    guard let self = self else { return }
                    guard (self.activeStreamsByDevice[deviceId] ?? []).contains(.ppi) else { return }
                    let tHost = Date().timeIntervalSince1970
                    let dev = self.deviceLabel(for: deviceId)
                    
                    for s in ppi.samples {
                        self.seqPPI &+= 1
                        let blocker = (s.blockerBit != 0) ? 1 : 0
                        let skinStat = (s.skinContactStatus != 0) ? 1 : 0
                        let skinSupp = (s.skinContactSupported != 0) ? 1 : 0
                        let te = BeatEventAligner.shared.alignPPI(deviceId: deviceId, ms: Int(s.ppInMs), tHost: tHost)
                        let pkt = PPIPacket(
                            device: dev, t_device: tHost, seq: self.seqPPI,
                            ms: Int(s.ppInMs), quality: Int(s.ppErrorEstimate),
                            blocker: blocker, skinContact: skinStat, skinSupported: skinSupp,
                            te: te
                        )
                        self.sendPacket(pkt)
                        self.log("PPI", "batch n=\(ppi.samples.count)")
                        
                        // 记录最新值
                        self.lastPpiMs = Int(s.ppInMs)
                    }
                    //Task { @MainActor in AppStore.shared.markSent() }
                }, onError: { [weak self] err in
                    self?.log("PPI", "stream error[\(deviceId)]: \(err)")
                })
            log("STREAM", "PPI started (Verity)")
        }
    }

    private func stop(kind: SignalKind, deviceId: String) {
        switch kind {
        case .hhr, .vhr, .rr:
            // 是否真正停 HR 由 applySelection/ensureHrStream 控制
            return
        case .ecg:
            ecgDisposable?.dispose();  ecgDisposable  = nil
            log("STREAM", "ECG stopped (H10)")
        case .hacc:
            haccDisposable?.dispose(); haccDisposable = nil
            log("STREAM", "ACC stopped (H10)")
        case .ppg:
            ppgDisposable?.dispose();  ppgDisposable  = nil
            log("STREAM", "PPG stopped (Verity)")
        case .vacc:
            vaccDisposable?.dispose(); vaccDisposable = nil
            log("STREAM", "ACC stopped (Verity)")
        case .ppi:
            ppiDisposable?.dispose();  ppiDisposable  = nil
            log("STREAM", "PPI stopped (Verity)")
        }
    }

}

// MARK: - Polar 观察者
extension PolarManager: PolarBleApiObserver {
    func deviceConnecting(_ identifier: PolarDeviceInfo) {
        connectingId = identifier.deviceId
        print("[CONNECTING] \(identifier.deviceId)")
    }

    func deviceConnected(_ identifier: PolarDeviceInfo) {
        connectingId = nil
        let id = identifier.deviceId
        let n  = identifier.name.lowercased()
        if n.contains("h10") {
            connectedH10Id = id
        } else if n.contains("sense") || n.contains("verity") || n.contains("oh1") {
            connectedVerityId = id
        }
        log("CONNECT", "已连接: \(id)")
        log("CONNECT", "等待采集页选择后再订阅数据流")
    }

    func deviceDisconnected(_ identifier: PolarDeviceInfo, pairingError: Bool) {
        let id = identifier.deviceId
        // 清理该设备的 HR/RR 与激活标记
        stopHr(id: id)
        activeStreamsByDevice[id] = nil
        selectedKindsByDevice[id] = nil

        let n = identifier.name.lowercased()
        if n.contains("h10") {
            connectedH10Id = nil
        } else if n.contains("sense") || n.contains("verity") || n.contains("oh1") {
            connectedVerityId = nil
        }
        log("CONNECT", "已断开: \(id) pairingError=\(pairingError)")
    }
}

extension PolarManager: PolarBleApiPowerStateObserver {
    func blePowerOn()  { blePoweredOn = true;  print("[BLE] power ON") }
    func blePowerOff() { blePoweredOn = false; print("[BLE] power OFF") }
}

extension PolarManager: PolarBleApiDeviceInfoObserver {
    // 电池信息
    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let idx = self.discovered.firstIndex(where: { $0.id == identifier }) {
                self.discovered[idx].batteryLevel = Int(batteryLevel)
            } else {
                // 极少数情况下连接早于扫描缓存，这里兜底插入一条
                self.discovered.append(
                    Discovered(id: identifier,
                               name: identifier,
                               rssi: 0,
                               connectable: true,
                               batteryLevel: Int(batteryLevel))
                )
            }
            self.log("DEVICE/BAT", "\(identifier): \(batteryLevel)%")
        }
    }
    
    func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {
        print("[DEVICE][CHG] \(identifier): \(chargingStatus)")
    }
    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        print("[DEVICE][DIS] \(identifier) \(uuid): \(value)")
    }
    func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        print("[DEVICE][DIS-KEY] \(identifier) \(key): \(value)")
    }
}

extension PolarManager: PolarBleApiDeviceFeaturesObserver {
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        print("[FEATURE] ready @\(identifier): \(feature)")
    }
}
