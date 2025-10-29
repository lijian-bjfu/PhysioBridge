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
import Combine
import PolarBleSdk
import RxSwift

final class PolarManager: NSObject, ObservableObject {

    // Singleton
    static let shared = PolarManager()
    // 回调
    typealias OpCompletion = (Error?) -> Void
    
    // MARK: - debug
    
    /// 识别 Polar SDK 的 “Already in state”报错
    @inline(__always)
    private func isAlreadyInStateError(_ error: Error) -> Bool {
        return String(describing: error).lowercased().contains("already in state")
    }
    
    // 详细日志总开关（从 FeatureFlags 读）
    private var verbose: Bool { FeatureFlags.consoleVerbose }

    // 仅用于“吵”的调试输出
    private func vlog(_ tag: String, _ msg: String) {
        guard verbose else { return }
        log(tag, msg)
    }
    
    #if DEBUG
    // deviceId -> kind -> count
    private var dbgStartCount: [String: [SignalKind: Int]] = [:]
    #endif

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
    // 保存hhr vhr 的最后数据
    @Published var lastHrByDevice: [String: UInt8] = [:]
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

    // RR 对齐器复位标记：每台设备只在会话首批 RR 复位一次
    private var rrAlignerReset: Set<String> = []

    // PPI 对齐器复位标记：每台设备只在会话首批 PPI 复位一次
    private var ppiAlignerReset: Set<String> = []

    // PPG fs 记录（选择后缓存）
    private var ppgFsSelected: Int = 0
    private var ecgFsSelected: Int = 0

    // 扫描心跳
    private var scanStartedAt: Date?
    
    // 用于UI信号流打印
    @Published var lastECGuV: Int? = nil      // ECG 最近一个 uV
    @Published var lastPPG1: Int? = nil       // PPG ch1 最近一个 a.u.
    @Published var lastPpiMs: Int? = nil      // PPI 最近一个 ms
    
    // HR 日志节流：最近一次记录的 bpm 及时间
    private var lastLoggedHR: UInt8 = 255
    private var lastHRLogAt: TimeInterval = 0

    // 记录传输样本信息
    struct CappingEvent {
        let deviceLabel: String
        let kind: SignalKind
        let samples: Int
        let bytes: Int
    }
    let capEvents = PassthroughSubject<CappingEvent, Never>()
    
    // MARK: - 串行队列：按设备串行执行 start/stop，避免“Already in state”
    private enum StreamOp  {
        case stop(SignalKind)
        case start(SignalKind)
        
        var description: String {
            switch self {
            case .stop(let k):  return "stop(\(k.title))"
            case .start(let k): return "start(\(k.title))"
            }
        }
    }

    // 记录每台设备当前正在处理的操作
    private var opQueueByDevice: [String: [StreamOp]] = [:]
    // 正在执行中的设备集合
    private var opProcessingByDevice: Set<String> = []
    // 记录每台设备当前正在处理的操作（用于去重）
    private var opCurrentByDevice: [String: StreamOp] = [:]
    private let opSerial = DispatchQueue(label: "pb.stream.ops", qos: .userInitiated)


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

    // MARK: - 传输数据
    private func sendPacket<T: Encodable>(_ packet: T) {
        if let json = TelemetryEncoder.encodeToJSONString(packet) {
            UDPSenderService.shared.send(json)
        }
    }
    // 限制发送数据的大小
    private func sendPPGCapped(
        devLabel: String,
        fs: Int,                      // 选用的采样率
        seqCounter: inout UInt64,     // 对应 self.seqPPG
        baseTime: TimeInterval,       // 本批 t_device 基准
        matrix: [[Int]]               // [样本行][通道] 的矩阵
    ) {
        let cap = FeatureFlags.maxPacketBytes
        let nTotal = matrix.count
        guard nTotal > 0 else { return }
        let ch = matrix.first?.count ?? 0
        var start = 0

        // 启发式起点：64 行或整批大小的较小者
        var guess = min(64, nTotal)

        while start < nTotal {
            var n = min(guess, nTotal - start)
            var sent = false

            while n > 0 {
                let end = start + n
                let slice = Array(matrix[start..<end])

                // 每段的 t_device = 基准 + 偏移样本 / fs
                let t0 = baseTime + Double(start) / Double(fs)

                // 递增序号（每个分段一个 seq）
                seqCounter &+= 1

                // 构包（沿用已有的 PPGPacket 字段命名）
                let pkt = PPGPacket(
                    device: devLabel,
                    t_device: t0,
                    seq: seqCounter,
                    fs: fs,
                    n: slice.count,
                    ch: ch,
                    mU: slice
                )

                if let json = TelemetryEncoder.encodeToJSONString(pkt),
                   json.utf8.count <= cap {
                    // 记录统计切分数据，本次子包字节大小 + 样本数
                    capEvents.send(.init(
                        deviceLabel: devLabel,
                        kind: .ppg,
                        samples: slice.count,
                        bytes: json.utf8.count
                    ))
    
                    UDPSenderService.shared.send(json)
                    start = end
                    guess = max(8, n)   // 下一次尝试用本次成功的大小，最低 8
                    sent = true
                    break
                } else {
                    // 超阈值就缩小，二分逼近
                    n = n / 2
                }
            }

            // 理论上不会走到这里；兜底：1 个样本也打不过去就强行发一行
            if !sent {
                let slice = [matrix[start]]
                let t0 = baseTime + Double(start) / Double(fs)
                seqCounter &+= 1
                let pkt = PPGPacket(
                    device: devLabel,
                    t_device: t0,
                    seq: seqCounter,
                    fs: fs,
                    n: 1,
                    ch: ch,
                    mU: slice
                )
                if let json = TelemetryEncoder.encodeToJSONString(pkt) {
                    
                    capEvents.send(.init(
                        deviceLabel: devLabel,
                        kind: .ppg,
                        samples: 1,
                        bytes: json.utf8.count
                    ))
                    
                    UDPSenderService.shared.send(json)
                }
                start += 1
                guess = 1
            }
        }
    }
    
    // 封顶发送：ECG（一维）
    private func sendECGCapped(
        devLabel: String,
        fs: Int,
        seqCounter: inout UInt64,
        baseTime: TimeInterval,
        uV: [Int]
    ) {
        let cap = FeatureFlags.maxPacketBytes
        let nTotal = uV.count
        guard nTotal > 0 else { return }

        var start = 0
        var guess = min(256, nTotal) // ECG 一维，起点可以稍大一点

        while start < nTotal {
            var n = min(guess, nTotal - start)
            var sent = false

            while n > 0 {
                let end = start + n
                let slice = Array(uV[start..<end])
                let t0 = baseTime + Double(start) / Double(fs)
                seqCounter &+= 1

                let pkt = ECGPacket(device: devLabel, t_device: t0, seq: seqCounter, fs: fs, uV: slice, n: slice.count)
                if let json = TelemetryEncoder.encodeToJSONString(pkt),
                   json.utf8.count <= cap {
                    
                    // 记录统计切分数据，本次子包字节大小 + 样本数
                    capEvents.send(.init(
                        deviceLabel: devLabel,
                        kind: .ecg,
                        samples: slice.count,
                        bytes: json.utf8.count
                    ))
                    
                    UDPSenderService.shared.send(json)
                    start = end
                    guess = max(32, n) // 记住本次成功规模
                    sent = true
                    break
                } else {
                    n = n / 2
                }
            }

            if !sent {
                let slice = [uV[start]]
                let t0 = baseTime + Double(start) / Double(fs)
                seqCounter &+= 1
                let pkt = ECGPacket(device: devLabel, t_device: t0, seq: seqCounter, fs: fs, uV: slice, n: 1)
                if let json = TelemetryEncoder.encodeToJSONString(pkt) {
                    capEvents.send(.init(
                        deviceLabel: devLabel,
                        kind: .ecg,
                        samples: 1,
                        bytes: json.utf8.count
                    ))
                    UDPSenderService.shared.send(json)
                }
                start += 1
                guess = 1
            }
        }
    }

    // 封顶发送：ACC（三通道矩阵，H10 & Verity 通用）
    private func sendACCCapped(
        devLabel: String,
        fs: Int,
        rangeG: Int,
        seqCounter: inout UInt64,
        baseTime: TimeInterval,
        triples: [[Int]],          // [样本][3]
        kind: SignalKind
    ) {
        let cap = FeatureFlags.maxPacketBytes
        let nTotal = triples.count
        guard nTotal > 0 else { return }

        var start = 0
        var guess = min(128, nTotal)

        while start < nTotal {
            var n = min(guess, nTotal - start)
            var sent = false

            while n > 0 {
                let end = start + n
                let slice = Array(triples[start..<end])
                let t0 = baseTime + Double(start) / Double(fs)
                seqCounter &+= 1

                let pkt = ACCPacket(
                    device: devLabel,
                    t_device: t0,
                    seq: seqCounter,
                    fs: fs,
                    mG: slice,
                    n: slice.count,
                    range_g: rangeG
                )
                if let json = TelemetryEncoder.encodeToJSONString(pkt),
                   json.utf8.count <= cap {
                    
                    // 记录统计切分数据，本次子包字节大小 + 样本数
                    capEvents.send(.init(
                        deviceLabel: devLabel,
                        kind: kind,
                        samples: slice.count,
                        bytes: json.utf8.count
                    ))
                    
                    UDPSenderService.shared.send(json)
                    start = end
                    guess = max(16, n)
                    sent = true
                    break
                } else {
                    n = n / 2
                }
            }

            if !sent {
                let slice = [triples[start]]
                let t0 = baseTime + Double(start) / Double(fs)
                seqCounter &+= 1
                let pkt = ACCPacket(
                    device: devLabel,
                    t_device: t0,
                    seq: seqCounter,
                    fs: fs,
                    mG: slice,
                    n: 1,
                    range_g: rangeG
                )
                if let json = TelemetryEncoder.encodeToJSONString(pkt) {
                    
                    capEvents.send(.init(
                        deviceLabel: devLabel,
                        kind: kind,
                        samples: 1,
                        bytes: json.utf8.count
                    ))
                    
                    UDPSenderService.shared.send(json)
                }
                start += 1
                guess = 1
            }
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
    // 移除某设备某信号的滑窗与已发布值
    private func clearLoss(deviceId: String, kind: SignalKind) {
        let k = lwKey(deviceId, kind)
        lossWindows.removeValue(forKey: k)
        var byKind = loss60sByDeviceAndKind[deviceId] ?? [:]
        byKind.removeValue(forKey: kind)
        loss60sByDeviceAndKind[deviceId] = byKind
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

    // MARK: - 扫描设备
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

    // MARK: - 连接设备
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

    // MARK: - 订阅用户选择信号
    @MainActor
    func applySelection(deviceId: String, kinds: Set<SignalKind>) {
        selectedKindsByDevice[deviceId] = kinds
        let was = activeStreamsByDevice[deviceId] ?? []
        
        // 差分只针对本设备
        let toStop  = was.subtracting(kinds)
        let toStart = kinds.subtracting(was)
        
        // MARK: debug 数据溯源2-该函数被调用了几次，以及是谁触发的
        #if DEBUG
        if verbose {
            let op = AppStore.shared.currentOpID
            // let reason = AppStore.shared.lastApplyReason
            // let caller = Thread.callStackSymbols.dropFirst(2).prefix(3).joined(separator: " | \n ")
            log("STREAM", "[currentOp = \(op)] 来自 applySelection 的操作 [\(deviceId.prefix(4))] was=\(was.map{$0.title}) new=\(kinds.map{$0.title}) stop=\(toStop.map{$0.title}) start=\(toStart.map{$0.title})")
            // log("STREAM", "[\(op)] 调用信息: \n \(caller)")
            // log("STREAM", "[reason=\(reason)] applySelection[\(deviceId.prefix(4))] was=\(was.map{$0.title}) new=\(kinds.map{$0.title}) stop=\(toStop.map{$0.title}) start=\(toStart.map{$0.title})")
        }
        #endif

        // 如果没有任何变化，直接同步 active 集合并返回
        if toStop.isEmpty && toStart.isEmpty {
            activeStreamsByDevice[deviceId] = kinds
            log("STREAM", "applySelection[\(deviceId.prefix(4))] -> NOOP")
            return
        }
        
        // 不再直接 for 循环 start/stop，而是改为入队
        enqueue(deviceId: deviceId, stops: Array(toStop), starts: Array(toStart))


        // HR/RR 底层订阅：只要本设备勾选了 HR 或 RR，就确保存在
        let needHR = kinds.contains(.hhr) || kinds.contains(.vhr) || kinds.contains(.rr) || kinds.contains(.ppi)
        if needHR { ensureHrStream(id: deviceId) } else { stopHr(id: deviceId) }

        activeStreamsByDevice[deviceId] = kinds
        log("STREAM", "applySelection[\(deviceId.prefix(4))] 确认选择 -> \(kinds.map{$0.title}.sorted().joined(separator: ","))")
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
        
        opSerial.async { [weak self] in
            self?.opQueueByDevice.removeAll()
            self?.opProcessingByDevice.removeAll()
            self?.opCurrentByDevice.removeAll()
        }
        
        lastECGuV = nil
        lastPPG1  = nil
        lastPpiMs = nil
        lastHrByDevice.removeAll()

        lossWindows.removeAll()
        loss60sByDeviceAndKind.removeAll()

        rrAlignerReset.removeAll()
        ppiAlignerReset.removeAll()

        log("STREAM", "stopAllStreams")
    }
    
    // MARK: - 队列化：串行执行 start/stop（主线程内真正做、队列只负责排程）
    private func enqueue(deviceId: String, stops: [SignalKind], starts: [SignalKind]) {
        opSerial.async {
            var q = self.opQueueByDevice[deviceId] ?? []
            
            // 去重辅助：判断队列里是否已有 .start(kind)
            func queueHasStart(_ kind: SignalKind) -> Bool {
                return q.contains { op in
                    if case .start(let k) = op { return k == kind }
                    return false
                }
            }
            // 判断“当前正在处理”的是否就是 .start(kind)
            func currentIsStart(_ kind: SignalKind) -> Bool {
                if let cur = self.opCurrentByDevice[deviceId],
                   case .start(let k) = cur, k == kind { return true }
                return false
            }
            
            // 先 stop 再 start，按字母序稳定排序，避免顺序抖动
            for k in stops.sorted(by: { $0.rawValue < $1.rawValue }) {
                // stop 通常幂等，但依然避免把完全相同的 stop 连续塞多条
                let alreadyInQueue = q.contains { op in
                    if case .stop(let x) = op { return x == k }; return false
                }
                let currentSame   = {
                    if let cur = self.opCurrentByDevice[deviceId],
                       case .stop(let x) = cur, x == k { return true }
                    return false
                }()

                if !alreadyInQueue && !currentSame {
                    q.append(.stop(k))
                } else {
                    self.vlog("STREAM", "queue[\(deviceId.prefix(4))] drop dup stop(\(k))")
                }
            }

            for k in starts.sorted(by: { $0.rawValue < $1.rawValue }) {
                // 关键：start 去重（队列里已有 or 正在处理中的相同 start 就丢弃）
                if queueHasStart(k) || currentIsStart(k) {
                    self.vlog("STREAM", "queue[\(deviceId.prefix(4))] drop dup start(\(k))")
                } else {
                    q.append(.start(k))
                }
            }
            
            self.opQueueByDevice[deviceId] = q
            
            // 关键一步：启动队列处理器
            self.processNextOp(deviceId)
        }
    }
    
    private func processNextOp(_ deviceId: String) {
        opSerial.async { [weak self] in
            guard let self else { return }
            // 若该设备当前正在处理，或者没有待处理，直接返回
            if self.opProcessingByDevice.contains(deviceId) { return }
            guard var q = self.opQueueByDevice[deviceId], !q.isEmpty else { return }

            // 取出队首，并标记“处理中”
            let op = q.removeFirst()
            self.opQueueByDevice[deviceId] = q
            self.opProcessingByDevice.insert(deviceId)
            // 标注“当前正在处理”的操作（用于去重
            self.opCurrentByDevice[deviceId] = op

            // 完成回调（单次触发），负责“让队列继续滚动”
            let finish: OpCompletion = { [weak self] error in
                guard let self else { return }
                if let error = error {
                    self.vlog("STREAM", "queue[\(deviceId.prefix(4))] FAILED on \(op) with error: \(error.localizedDescription)")
                }
                self.opSerial.async {
                    // 清理“当前 op”与“正在处理”标志
                    self.opCurrentByDevice[deviceId] = nil
                    self.opProcessingByDevice.remove(deviceId)
                    // 继续处理下一条（若有）
                    self.processNextOp(deviceId)
                }
            }

            // 转到主线程执行，因为 Polar SDK 需要
            DispatchQueue.main.async {
                switch op {
                case .start(let kind):
                    self.start(kind: kind, deviceId: deviceId, completion: finish)
                case .stop(let kind):
                    self.stop(kind: kind, deviceId: deviceId, completion: finish)
                }
            }
        }
    }

    // MARK: - star(.. 采集ECG, ACC, PPI, PPG
    private func ensureHrStream(id: String) {
        if hrDisposableById[id] != nil { return }
        startHr(id: id)
    }

    /// 主启动函数（调度器）
    private func start(kind: SignalKind, deviceId: String, completion: @escaping OpCompletion) {
        switch kind {
        case .ecg:  startECG(deviceId: deviceId, completion: completion)
        case .hacc: startHACC(deviceId: deviceId, completion: completion)
        case .vacc: startVACC(deviceId: deviceId, completion: completion)
        case .ppg:  startPPG(deviceId: deviceId, completion: completion)
        case .ppi:  startPPI(deviceId: deviceId, completion: completion)
        case .hhr, .vhr, .rr:
            // 由 HR 主流管理，不直接启动，直接成功回调
            completion(nil)
        }
    }

    /// 主停止函数（调度器）
    private func stop(kind: SignalKind, deviceId: String, completion: @escaping OpCompletion) {
        switch kind {
        case .ecg:  stopECG(deviceId: deviceId, completion: completion)
        case .hacc: stopHACC(deviceId: deviceId, completion: completion)
        case .vacc: stopVACC(deviceId: deviceId, completion: completion)
        case .ppg:  stopPPG(deviceId: deviceId, completion: completion)
        case .ppi:  stopPPI(deviceId: deviceId, completion: completion)
        case .hhr, .vhr, .rr:
            completion(nil)
        }
    }
    
    // MARK: - startHR
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
                    self.lastHrByDevice[id] = s.hr // 按照设备记录数据
                    self.lastHr = s.hr
                    self.seqHR &+= 1
                    let p = HRPacket(device: devLabel, t_device: tHost, seq: self.seqHR, bpm: Int(s.hr))
                    self.sendPacket(p)
                    
                    let now = Date().timeIntervalSince1970
                    if self.lastLoggedHR != s.hr || now - self.lastHRLogAt > 3 {
                        self.log("HR", "\(devLabel) bpm=\(s.hr)")
                        self.lastLoggedHR = s.hr
                        self.lastHRLogAt = now
                    }
                    //Task { @MainActor in AppStore.shared.markSent() }
                }

                // 2) RR：展开每个间期成单事件
                if chosen.contains(.rr) {
                    let rrs = batch.flatMap { $0.rrsMs }
                    // 首批 RR 到达时复位对齐器（每台设备一次），避免跨会话残留
                    if !self.rrAlignerReset.contains(id) {
                        BeatEventAligner.shared.reset(stream: .rr, deviceId: id)
                        self.rrAlignerReset.insert(id)
                        self.vlog("RR", "BeatEventAligner.reset(.rr) @\(id.prefix(4))")
                    }
                    let events = BeatEventAligner.shared.alignRRBatch(deviceId: id, rrsMs: rrs, tHost: tHost)
                    for (rr, te) in zip(rrs, events) {
                        self.lastRrMs.append(rr)
                        self.seqRR &+= 1
                        let prr = RRPacket(device: devLabel, t_device: tHost, seq: self.seqRR, ms: rr, te: te)
                        self.vlog("Time check RR", "seq=\(self.seqRR) ms=\(rr) t_host=\(String(format: "%.6f", tHost))")
                        self.sendPacket(prr)
                        self.vlog("RR", "\(devLabel) start \(rr)")
                    }
                }
            }, onError: { [weak self] err in
                self?.log("HR", "stream error[\(id)]: \(err)")
            })
    }

    private func stopHr(id: String) {
        hrDisposableById[id]?.dispose()
        hrDisposableById[id] = nil
        rrAlignerReset.remove(id)
        lastHrByDevice.removeValue(forKey: id)
    }

    private func stopHrAll() {
        for (id, d) in hrDisposableById { d.dispose(); hrDisposableById[id] = nil }
        hrDisposableById.removeAll()
        rrAlignerReset.removeAll()
    }
    
    // MARK: startECG
    private func startECG(deviceId: String, completion: @escaping OpCompletion) {
        ecgDisposable?.dispose()
        var isDone = false
        let completeOnce: OpCompletion = { err in guard !isDone else { return }; isDone = true; completion(err) }
        
        var signaledReady = false
        let dev = deviceLabel(for: deviceId)

        ecgDisposable = api.requestStreamSettings(deviceId, feature: .ecg)
            .asObservable()
            .flatMap { [weak self] settings -> Observable<PolarEcgData> in
                guard let self = self else { return .empty() }
                
                let s = settings.settings
                let srSet = Array(s[.sampleRate] ?? []).sorted()
                let rsSet = Array(s[.resolution] ?? []).sorted()
                // self.log("ECG", "H10 available settings: sr=\(srSet) res=\(rsSet)")
                
                let sr: UInt32 = srSet.contains(130) ? 130 : (srSet.first ?? 130)
                let rs: UInt32 = rsSet.contains(14)  ? 14  : (rsSet.first ?? 14)
                
                self.ecgFsSelected = Int(sr)
                let chosen = PolarSensorSetting([.sampleRate: sr, .resolution: rs])
                self.log("ECG", "start settings fs=\(sr)Hz res=\(rs)bit")
                return self.api.startEcgStreaming(deviceId, settings: chosen)
            }
            .do(
                onSubscribe: { [weak self] in
                    #if DEBUG
                    self?.vlog("ECG", "[diag] onSubscribe startEcgStreaming")
                    #endif
                    // **不再在 onSubscribe 就 completeOnce(nil)**
                },
                onDispose: { [weak self] in
                    #if DEBUG
                    self?.vlog("ECG", "[diag] onDispose startEcgStreaming")
                    #endif
                }
            )
            .observe(on: MainScheduler.instance)
            .subscribe( onNext: { [weak self] ecg in
                    guard let self = self else { return }
                    // 只看该设备的激活集
                    guard (self.activeStreamsByDevice[deviceId] ?? []).contains(.ecg) else { return }
                
                    // 回调完成标记要在onNext中标记
                    // 回调是否完成以signaledReady为标记
                    if !signaledReady {
                        signaledReady = true
                        completeOnce(nil)
                        self.vlog("STREAM", "queue[\(deviceId.prefix(4))] did start(\(SignalKind.ecg))")
                    }
                
                    let t = Date().timeIntervalSince1970
                    let uV = ecg.map { Int($0.voltage) }
                    
                    // 打印 发出 ecg 的时间
                    self.vlog("Time check ECG", "send ECG batch t_host=\(String(format: "%.6f", t)) n=\(uV.count)")
                    // 如果发送了 baseTime 版本，也打印
                    // e.g. inside FeatureFlags.cappedTxEnabled branch after sendECGCapped 调用：
                    // self.vlog("Time check ECG", "capped send ECG baseTime = \(String(format: "%.6f", t)) n=\(uV.count)")
                
                    if FeatureFlags.cappedTxEnabled {
                        self.sendECGCapped(
                            devLabel: dev,
                            fs: self.ecgFsSelected,                 // 你上面挑的就是 130
                            seqCounter: &self.seqECG,
                            baseTime: t,
                            uV: uV
                        )
                        self.log("ECG", "capped batch n=\(uV.count)")
                    } else {
                        self.seqECG &+= 1
                        let pkt = ECGPacket(device: dev, t_device: t, seq: self.seqECG, fs: 130, uV: uV, n: uV.count)
                        self.sendPacket(pkt)
                        self.log("ECG", "batch n=\(uV.count)")
                    }
                    
                    // 计算ecg丢包
                    self.recordLoss(deviceId: deviceId, kind: .ecg, samples: uV.count, fs: 130)
                    
                    // 记录ecg最新值用于UI打印
                    self.lastECGuV = uV.last
                    
                },
                onError: { [weak self] err in
                    if self?.isAlreadyInStateError(err) == true {
                        self?.vlog("ECG", "Stream already started. Treating as idempotent success.")
                        self?.activeStreamsByDevice[deviceId]?.insert(.ecg)
                        if !signaledReady { completeOnce(nil); signaledReady = true }
                        completeOnce(nil)
                    } else {
                        self?.vlog("ECG", "stream error[\(deviceId)]: \(err)")
                        completeOnce(err)
                    }
                }
            )
    }
    private func stopECG(deviceId: String, completion: @escaping OpCompletion) {
        // 1) 取消订阅
        ecgDisposable?.dispose()
        ecgDisposable = nil

        // 2) 更新内部状态：该设备的 .vacc 已不再处于“启用中”
        activeStreamsByDevice[deviceId]?.remove(.ecg)

        // 3) 清理丢包统计/缓存
        clearLoss(deviceId: deviceId, kind: .ecg)

        // 4) 日志
        log("STREAM", "ECG stopped (H10)")

        // 5) 关键：通知队列“这一条已完成”，让下一条操作能被继续处理
        completion(nil)
    }
    
    // MARK: startPPG
    private func startPPG(deviceId: String, completion: @escaping OpCompletion) {
        ppgDisposable?.dispose()
        var isDone = false
        let completeOnce: OpCompletion = { err in guard !isDone else { return }; isDone = true; completion(err) }

        let dev = deviceLabel(for: deviceId)
        var signaledReady = false  // <—— 仅在首帧到达时置 true 并回调完成

        ppgDisposable = api.requestStreamSettings(deviceId, feature: .ppg)
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
                self.vlog("PPG", "start settings fs=\(sr)Hz res=\(rs)bit ch=\(ch)")
                return self.api.startPpgStreaming(deviceId, settings: chosen)
            }
            .do(
                onSubscribe: { [weak self] in
                    #if DEBUG
                    self?.vlog("PPG", "[diag] onSubscribe startPpgStreaming")
                    #endif
                    // **不再在 onSubscribe 就 completeOnce(nil)**
                },
                onDispose: { [weak self] in
                    #if DEBUG
                    self?.vlog("PPG", "[diag] onDispose startPpgStreaming")
                    #endif
                }
            )
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] ppg in
                    guard let self = self else { return }
                    guard (self.activeStreamsByDevice[deviceId] ?? []).contains(.ppg) else { return }

                    // 回调完成标记要在onNext中标记
                    // 回调是否完成以signaledReady为标记
                    if !signaledReady {
                        signaledReady = true
                        completeOnce(nil)
                        self.vlog("STREAM", "queue[\(deviceId.prefix(4))] did start(\(SignalKind.ppg))")
                    }

                    let t = Date().timeIntervalSince1970
                    let n = ppg.samples.count
                    let ch = ppg.samples.first?.channelSamples.count ?? 0
                    let matrix = ppg.samples.map { $0.channelSamples.map(Int.init) }

                    if FeatureFlags.cappedTxEnabled {
                        // 限制大小传输：现切现发（保持你现有 PPGPacket 结构）
                        sendPPGCapped(
                            devLabel: dev,
                            fs: self.ppgFsSelected,
                            seqCounter: &self.seqPPG,
                            baseTime: t,
                            matrix: matrix
                        )
                        self.vlog("PPG", "capped batch n=\(n) ch=\(ch)")
                    } else {
                        self.seqPPG &+= 1
                        let pkt = PPGPacket(device: dev, t_device: t, seq: self.seqPPG, fs: self.ppgFsSelected, n: n, ch: ch, mU: matrix)
                        self.sendPacket(pkt)
                        self.vlog("PPG", "batch n=\(n) channels=\(ch)")
                    }

                    // 丢包估计
                    self.recordLoss(deviceId: deviceId, kind: .ppg, samples: n, fs: self.ppgFsSelected)

                    // 记录最新 PPG 第一通道
                    let ch1 = matrix.last?.first
                    self.lastPPG1 = ch1
                },
                onError: { [weak self] err in
                    if self?.isAlreadyInStateError(err) == true {
                        // 设备说“本来就在该状态”，视为幂等成功
                        self?.vlog("PPG", "Stream already started. Treating as idempotent success.")
                        self?.activeStreamsByDevice[deviceId]?.insert(.ppg)
                        if !signaledReady { completeOnce(nil); signaledReady = true }
                    } else {
                        self?.vlog("PPG", "stream error[\(deviceId)]: \(err)")
                        completeOnce(err)
                    }
                }
            )
        log("STREAM", "PPG starting (Verity)...")
    }
    private func stopPPG(deviceId: String, completion: @escaping OpCompletion) {
        // 1) 取消订阅
        ppgDisposable?.dispose()
        ppgDisposable = nil

        // 2) 更新内部状态：该设备的 .vacc 已不再处于“启用中”
        activeStreamsByDevice[deviceId]?.remove(.ppg)

        // 3) 清理丢包统计/缓存
        clearLoss(deviceId: deviceId, kind: .ppg)

        // 4) 日志
        log("STREAM", "PPG stopped (Verity)")

        // 5) 关键：通知队列“这一条已完成”，让下一条操作能被继续处理
        completion(nil)
    }
    
    // MARK: startPPI
    private func startPPI(deviceId: String, completion: @escaping OpCompletion) {
        ppiDisposable?.dispose()
        var isDone = false
        let completeOnce: OpCompletion = { err in guard !isDone else { return }; isDone = true; completion(err) }
        
        var signaledReady = false

        ppiDisposable = api.startPpiStreaming(deviceId)
            .do(
                onSubscribe: { [weak self] in
                    #if DEBUG
                    self?.vlog("PPI", "[diag] onSubscribe startPpiStreaming")
                    #endif
                    // **不再在 onSubscribe 就 completeOnce(nil)**
                },
                onDispose: { [weak self] in
                    #if DEBUG
                    self?.vlog("PPI", "[diag] onDispose startPpiStreaming")
                    #endif
                }
            )
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] ppi in
                    guard let self = self, (self.activeStreamsByDevice[deviceId] ?? []).contains(.ppi) else { return }
                    
                    // 首帧到达，宣布“就绪”
                    if !signaledReady {
                        signaledReady = true
                        completeOnce(nil)
                        self.vlog("STREAM", "queue[\(deviceId.prefix(4))] did start(\(SignalKind.ppi))")
                    }
                    
                    let tHost = Date().timeIntervalSince1970
                    let dev = self.deviceLabel(for: deviceId)
                    
                    // 首批 PPI 到达时复位对齐器（每台设备一次），避免跨会话残留
                    if !self.ppiAlignerReset.contains(deviceId) {
                        BeatEventAligner.shared.reset(stream: .ppi, deviceId: deviceId)
                        self.ppiAlignerReset.insert(deviceId)
                        self.vlog("PPI", "BeatEventAligner.reset(.ppi) @\(deviceId.prefix(4))")
                    }

                    for s in ppi.samples {
                        self.seqPPI &+= 1
                        let te = BeatEventAligner.shared.alignPPI(deviceId: deviceId, ms: Int(s.ppInMs), tHost: tHost)
                        let pkt = PPIPacket(
                            device: dev, t_device: tHost, seq: self.seqPPI,
                            ms: Int(s.ppInMs), quality: Int(s.ppErrorEstimate),
                            blocker: (s.blockerBit != 0) ? 1 : 0,
                            skinContact: (s.skinContactStatus != 0) ? 1 : 0,
                            skinSupported: (s.skinContactSupported != 0) ? 1 : 0,
                            te: te
                        )
                        self.sendPacket(pkt)
                        self.lastPpiMs = Int(s.ppInMs)
                    }
                },
                onError: { [weak self] err in
                    if self?.isAlreadyInStateError(err) == true {
                        self?.log("PPI", "Stream already started. Treating as idempotent success.")
                        self?.activeStreamsByDevice[deviceId]?.insert(.ppi)
                        if !signaledReady { completeOnce(nil); signaledReady = true }
                        completeOnce(nil)
                    } else {
                        self?.log("PPI", "stream error[\(deviceId)]: \(err)")
                        completeOnce(err)
                    }
                }
            )
        log("STREAM", "PPI starting (Verity)...")
    }
    
    private func stopPPI(deviceId: String, completion: @escaping OpCompletion) {
        // 1) 取消订阅
        ppiDisposable?.dispose()
        ppiDisposable = nil

        // 2) 更新内部状态：该设备的 .vacc 已不再处于“启用中”
        activeStreamsByDevice[deviceId]?.remove(.ppi)

        // 清理 PPI 对齐器复位标记
        ppiAlignerReset.remove(deviceId)

        // 3) 清理丢包统计/缓存
        clearLoss(deviceId: deviceId, kind: .ppi)

        // 4) 日志
        log("STREAM", "PPI stopped (Verity)")

        // 5) 关键：通知队列“这一条已完成”，让下一条操作能被继续处理
        completion(nil)
    }
    
    // MARK: startHACC
    private func startHACC(deviceId: String, completion: @escaping OpCompletion) {
        haccDisposable?.dispose()
        var isDone = false
        let completeOnce: OpCompletion = { err in guard !isDone else { return }; isDone = true; completion(err) }
        
        var signaledReady = false
        
        let dev = deviceLabel(for: deviceId)
        var selSr: UInt32 = 0

        haccDisposable = api.requestStreamSettings(deviceId, feature: .acc)
            .asObservable()
            .flatMap { [weak self] settings -> Observable<PolarAccData> in
                guard let self = self else { return .empty() }
                let s = settings.settings
                let srSet = Array(s[.sampleRate] ?? []).sorted()
                let rgSet = Array(s[.range] ?? []).sorted()
                let rsSet = Array(s[.resolution] ?? []).sorted()
                guard let sr = (srSet.contains(50) ? 50 : srSet.first) else {
                    self.log("ACC", "H10 no sampleRate available, abort")
                    return .empty()
                }
                selSr = sr
                var chosenDict: [PolarSensorSetting.SettingType: UInt32] = [.sampleRate: sr]
                if let rg = (rgSet.contains(4) ? 4 : rgSet.first) { chosenDict[.range] = rg }
                if let rs = (rsSet.contains(16) ? 16 : rsSet.first) { chosenDict[.resolution] = rs }
                let chosen = PolarSensorSetting(chosenDict)
                self.log("ACC", "H10 start fs=\(sr)Hz range=\(chosenDict[.range] ?? 0)G res=\(chosenDict[.resolution] ?? 0)bit")
                return self.api.startAccStreaming(deviceId, settings: chosen)
            }
            .do(
                onSubscribe: { [weak self] in
                    #if DEBUG
                    self?.vlog("HACC", "[diag] onSubscribe startAccStreaming")
                    #endif
                },
                onDispose: { [weak self] in
                    #if DEBUG
                    self?.vlog("HACC", "[diag] onDispose startAccStreaming")
                    #endif
                }
            )
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] acc in
                    guard let self = self, (self.activeStreamsByDevice[deviceId] ?? []).contains(.hacc) else { return }
                    
                    // 首帧到达，宣布“就绪”
                    if !signaledReady {
                        signaledReady = true
                        completeOnce(nil)
                        self.vlog("STREAM", "queue[\(deviceId.prefix(4))] did start(\(SignalKind.hacc))")
                    }
                    
                    let t = Date().timeIntervalSince1970
                    let triples = acc.map { [Int($0.x), Int($0.y), Int($0.z)] }
                    let fsInt = selSr == 0 ? 50 : Int(selSr)
                    if FeatureFlags.cappedTxEnabled {
                        self.sendACCCapped(devLabel: dev, fs: fsInt, rangeG: 4, seqCounter: &self.seqHACC, baseTime: t, triples: triples, kind: .hacc)
                    } else {
                        self.seqHACC &+= 1
                        let pkt = ACCPacket(device: dev, t_device: t, seq: self.seqHACC, fs: fsInt, mG: triples, n: triples.count, range_g: 4)
                        self.sendPacket(pkt)
                    }
                    self.recordLoss(deviceId: deviceId, kind: .hacc, samples: triples.count, fs: fsInt)
                },
                onError: { [weak self] err in
                    if self?.isAlreadyInStateError(err) == true {
                        self?.log("HACC", "Stream already started. Treating as idempotent success.")
                        self?.activeStreamsByDevice[deviceId]?.insert(.hacc)
                        if !signaledReady { completeOnce(nil); signaledReady = true }
                        completeOnce(nil)
                    } else {
                        self?.log("ACC", "H10 stream error[\(deviceId)]: \(err)")
                        completeOnce(err)
                    }
                }
            )
        log("STREAM", "ACC starting (H10)...")
    }
    private func stopHACC(deviceId: String, completion: @escaping OpCompletion) {
        // 1) 取消订阅
        haccDisposable?.dispose()
        haccDisposable = nil

        // 2) 更新内部状态：该设备的 .vacc 已不再处于“启用中”
        activeStreamsByDevice[deviceId]?.remove(.hacc)

        // 3) 清理丢包统计/缓存
        clearLoss(deviceId: deviceId, kind: .hacc)

        // 4) 日志
        log("STREAM", "HACC stopped (H10)")

        // 5) 关键：通知队列“这一条已完成”，让下一条操作能被继续处理
        completion(nil)
    }
    
    // MARK: startVACC
    private func startVACC(deviceId: String, completion: @escaping OpCompletion) {
        vaccDisposable?.dispose()
        var isDone = false
        let completeOnce: OpCompletion = { err in guard !isDone else { return }; isDone = true; completion(err) }
        var signaledReady = false
        
        let dev = deviceLabel(for: deviceId)
        var selSr: UInt32 = 0
        var selRg: UInt32 = 0

        vaccDisposable = api.requestStreamSettings(deviceId, feature: .acc)
            .asObservable()
            .flatMap { [weak self] (settings: PolarSensorSetting) -> Observable<PolarAccData> in
                guard let self = self else { return .empty() }
                let s = settings.settings
                let srSet = Array(s[.sampleRate] ?? []).sorted()
                let rgSet = Array(s[.range] ?? []).sorted()
                let rsSet = Array(s[.resolution] ?? []).sorted()
                guard let sr = (srSet.contains(52) ? 52 : (srSet.contains(50) ? 50 : srSet.first)) else {
                    self.log("ACC", "Verity no sampleRate available, abort")
                    return .empty()
                }
                selSr = sr
                var chosen: [PolarSensorSetting.SettingType: UInt32] = [.sampleRate: sr]
                if let rg = (rgSet.contains(8) ? 8 : (rgSet.contains(4) ? 4 : rgSet.first)) {
                    chosen[.range] = rg; selRg = rg
                } else { selRg = 0 }
                if let rs = (rsSet.contains(16) ? 16 : rsSet.first) { chosen[.resolution] = rs }
                if let ch = Array(s[.channels] ?? []).first { chosen[.channels] = ch }
                let setting = PolarSensorSetting(chosen)
                self.log("ACC", "Verity start fs=\(sr)Hz range=\(selRg)G res=\(chosen[.resolution] ?? 0)bit")
                return self.api.startAccStreaming(deviceId, settings: setting)
            }
            .do(
                onSubscribe: { [weak self] in
                    #if DEBUG
                    self?.vlog("ACC", "[diag] onSubscribe startAccStreaming")
                    #endif
                },
                onDispose: { [weak self] in
                    #if DEBUG
                    self?.vlog("ACC", "[diag] onDispose startAccStreaming")
                    #endif
                }
            )
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] acc in
                    guard let self = self, (self.activeStreamsByDevice[deviceId] ?? []).contains(.vacc) else { return }
                    
                    // 首帧到达，宣布“就绪”
                    if !signaledReady {
                        signaledReady = true
                        completeOnce(nil)
                        self.vlog("STREAM", "queue[\(deviceId.prefix(4))] did start(\(SignalKind.vacc))")
                    }
                    
                    let t = Date().timeIntervalSince1970
                    let triples = acc.map { [Int($0.x), Int($0.y), Int($0.z)] }
                    let fsInt = selSr == 0 ? 52 : Int(selSr)
                    let rangeInt = selRg == 0 ? 8 : Int(selRg)
                    if FeatureFlags.cappedTxEnabled {
                        self.sendACCCapped(devLabel: dev, fs: fsInt, rangeG: rangeInt, seqCounter: &self.seqVACC, baseTime: t, triples: triples, kind: .vacc)
                    } else {
                        self.seqVACC &+= 1
                        let pkt = ACCPacket(device: dev, t_device: t, seq: self.seqVACC, fs: fsInt, mG: triples, n: triples.count, range_g: rangeInt)
                        self.sendPacket(pkt)
                    }
                    self.recordLoss(deviceId: deviceId, kind: .vacc, samples: triples.count, fs: fsInt)
                },
                onError: { [weak self] err in
                    if self?.isAlreadyInStateError(err) == true {
                        self?.log("VACC", "Stream already started. Treating as idempotent success.")
                        self?.activeStreamsByDevice[deviceId]?.insert(.vacc)
                        if !signaledReady { completeOnce(nil); signaledReady = true }
                        completeOnce(nil)
                    } else {
                        self?.log("ACC", "Verity stream error[\(deviceId)]: \(err)")
                        completeOnce(err)
                    }
                }
            )
        log("STREAM", "ACC starting (Verity)...")
    }
    
    private func stopVACC(deviceId: String, completion: @escaping OpCompletion) {
        // 1) 取消订阅
        vaccDisposable?.dispose()
        vaccDisposable = nil

        // 2) 更新内部状态：该设备的 .vacc 已不再处于“启用中”
        activeStreamsByDevice[deviceId]?.remove(.vacc)

        // 3) 清理丢包统计/缓存
        clearLoss(deviceId: deviceId, kind: .vacc)

        // 4) 日志
        log("STREAM", "VACC stopped (Verity)")

        // 5) 关键：通知队列“这一条已完成”，让下一条操作能被继续处理
        completion(nil)
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
        rrAlignerReset.remove(id)
        ppiAlignerReset.remove(id)

        let n = identifier.name.lowercased()
        if n.contains("h10") {
            connectedH10Id = nil
        } else if n.contains("sense") || n.contains("verity") || n.contains("oh1") {
            connectedVerityId = nil
        }
        
        opSerial.async { [weak self] in
            self?.opQueueByDevice[id] = []
            self?.opProcessingByDevice.remove(id)
            self?.opCurrentByDevice.removeValue(forKey: id)
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

// MARK: - Concurrency bridging for GCD closures
extension PolarManager: @unchecked Sendable {}
