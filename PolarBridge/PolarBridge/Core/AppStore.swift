//
//  AppStore.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//  把分散在界面里的状态（目标 IP/端口、是否在发、累计条数、最近发送时间、设备连接状态等）集中到一个可观察的全局对象里，后续 UI 和服务层都只跟它打交道。

// AppStore.swift
// 作用：集中管理全局状态（UI 与服务共享的“单一真相”）

import Foundation
import Combine


// ====== 采集信号的标准枚举 ======
enum SignalKind: String, CaseIterable, Hashable, Identifiable {
    case ppi, ppg, ecg, rr, vhr, vacc, hhr, hacc
    var id: String { rawValue }

    /// UI 上显示的中文名
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

    /// 可选：一个系统图标名，后面 DataPill 可以用
    var sfSymbol: String {
        switch self {
        case .ppi: return "bolt.heart"
        case .ppg: return "waveform.path.ecg"
        case .ecg: return "waveform"
        case .rr: return "rhombus"
        case .vhr:  return "Verity's heart.fill"
        case .hhr:  return "H10's heart.fill"
        case .vacc: return "Verity's gyroscope"
        case .hacc: return "H10's gyroscope"
        }
    }
    
    // 只读元数据（单位/采样率/简介
    var unit: String {
        switch self {
        case .rr:  return "ms"
        case .ecg: return "μV"
        case .ppi: return "ms"
        case .ppg: return "a.u."
        case .vhr:  return "bpm"
        case .hhr:  return "bpm"
        case .vacc: return "mG"
        case .hacc: return "mG"
        }
    }
    var defaultFs: Int? {
        switch self {
        case .ecg: return 130          // Polar H10 ECG 固定 130 Hz
        case .hacc: return 50           // MVP 先以 50 Hz 为默认
        default:   return nil
        }
    }
    var defaultRangeG: Int? {
        switch self {
        case .hacc: return 4            // MVP 先以 ±4G 为默认
        default:   return nil
        }
    }
    var shortDesc: String {
        switch self {
        case .rr:  return "相邻心搏间期"
        case .ecg: return "心电微伏采样"
        case .ppi: return "心搏间期（相机/光电）"
        case .ppg: return "光体积脉搏波"
        case .vhr:  return "每秒心率"
        case .hhr:  return "每秒心率"
        case .vacc: return "三轴体动加速度"
        case .hacc: return "三轴体动加速度"
        }
    }

}

// 设备状态（先够用，后续再细化）
enum DeviceStatus: String, Codable {
    case unknown
    case available
    case connected
}

// UDP 目标
struct UdpTarget: Codable, Equatable {
    var host: String
    var port: Int
    var address: String { "\(host):\(port)" }
    var isValid: Bool { !host.isEmpty && (1...65535).contains(port) }
}


@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    
    // 绑定设备
    private var cancellables = Set<AnyCancellable>()
    // 用以下两个变量锚定“当前正要连接的那个设备”
    private var lastChosenH10Id: String? = nil
    private var lastChosenVerityId: String? = nil
    
    // 是否启用内置模拟数据（先默认 true，等接入 Polar 后可关掉）
    @Published var simulateData: Bool = false
    // 内部记录定时器（仅在 simulateData 为 true 时启用）
    private var simTimer: Timer?

    // --- 发送与目标 ---
    @Published var udpTarget = UdpTarget(host: AppConfig.defaultUDPHost, port: AppConfig.defaultUDPPort)
    private var dataSender = UdpSender(host: AppConfig.defaultUDPHost, port: UInt16(AppConfig.defaultUDPPort))

    
    @Published var dataTimer: Timer?
    
    // --- 采集状态信息 ---
    // 是否处于采集中
    @Published var isCollecting: Bool = false
    @Published var collectCount: Int = 0
    @Published var lastError: String? = nil
    @Published var lastSentAt: Date?
    // 受试者编号（先手动填写，后续做页面）
    @Published var subjectID: String? = nil
    // 本次采集编号（进入采集页生成一次）
    @Published var trialID: String = "0"
    
    // 已发送标记计数
    @Published var markerCount: Int = 0

    // --- 设备状态 ---
    // 设备连接状态（UI 只读，后面由 Polar SDK/扫描器来更新）
    @Published var verityState: DeviceState = .not_found
    @Published var h10State: DeviceState    = .not_found
    // 储存是否连接设备的信息
    var verityConnected: Bool { verityState == .connected }
    var h10Connected:    Bool { h10State    == .connected }
    // --- 当前“点亮”的数据源（采集页用）---
    @Published var activeSources: [DataSource] = []
    
    /// “可订阅的信号”直接查看枚举状态
    /// 约定：Verity -> PPI / PPG / HR，H10 -> ECG / HR
    var availableSignals: Set<SignalKind> {
        var s: Set<SignalKind> = []
        if verityState == .connected { s.formUnion([.ppi, .ppg, .vhr, .vacc]) }
        if h10State    == .connected { s.formUnion([.ecg, .hhr, .rr, .hacc]) }
        return s
    }
    /// 用户在采集页实际勾选的信号集合（由 UI 改动）
    @Published var selectedSignals: Set<SignalKind> = []
    
    // --- 计时 ---
    // 采集开始时间（用于计时）
    @Published var sessionStart: Date? = nil
    @Published var sessionStop: Date?  = nil
    
    // --- MARK 标记 ---
    // 标记的点击必须按照基线开始 / 诱导开始 / 诱导结束 / 干预开始 / 干预结束的顺序
    // 用以下变量控制
    let markerSequence: [MarkerLabel] = [
        .baseline_start, .stim_start, .stim_end, .intervention_start, .intervention_end
    ]
    // 标记流程位置：-1 表示尚未开始；0 表示已完成 baseline_start，以此类推
    @Published private(set) var markerStep: Int = -1
    // 当前已激活的标记（用于 UI 高亮）；nil 表示未激活
    var markerActive: MarkerLabel? {
        guard markerStep >= 0 && markerStep < markerSequence.count else { return nil }
        return markerSequence[markerStep]
    }
    // 下一步允许点击的标记（UI 启用条件）
    var markerAllowedNext: MarkerLabel? {
        let next = markerStep + 1
        return (next < markerSequence.count) ? markerSequence[next] : nil
    }
    private var baselineStart: Date? = nil
    private var baselineAccum: TimeInterval = 0

    private var stimStart: Date? = nil
    private var stimAccum: TimeInterval = 0

    private var intervStart: Date? = nil
    private var intervAccum: TimeInterval = 0

    private init() {
        // 启动时就建立与 PolarManager 的绑定
        bindPolar()
        // 确保 MarkerBus → UDP 的桥在应用期内一直存活
        _ = UdpMarkerBridge.shared
    }
    
    // 将 PolarManager 的事件映射到 h10State
    private func bindPolar() {
        let pm = PolarManager.shared

        // 1) 扫描结果：出现 verity/H10 → discovered；否则在未连接时 not_found
        pm.$discovered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                guard let self = self else { return }
                // H10 的发现状态
                let hasH10 = list.contains { $0.name.localizedCaseInsensitiveContains("h10") }
                if self.h10State != .connected {
                    self.h10State = hasH10 ? .discovered : .not_found
                }
                
                // Verity（含 Verity Sense 两个名字搜索）的发现状态
                let hasVerity = list.contains {
                    let n = $0.name.lowercased()
                    return n.contains("sense") || n.contains("verity")
                }
                if self.verityState != .connected {
                    self.verityState = hasVerity ? .discovered : .not_found
                    // 可选的一次性调试输出，便于确认绑定生效
                    // print("[AppStore][Verity] discovered=\(hasVerity)")
                }
            }
            .store(in: &cancellables)

        // 2) 连接中：若是我们刚刚选择的设备，则进入 connecting
        pm.$connectingId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self = self else { return }
                if let id = id, id == self.lastChosenH10Id {
                    self.h10State = .connecting
                }
                if let id = id, id == self.lastChosenVerityId {
                    self.verityState = .connecting
                }
            }
            .store(in: &cancellables)

        // 3) 已连接/断开：根据 id 判断是否为 H10（用 lastChosenH10Id 锚定）
        pm.$connectedId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self = self else { return }
                if let id = id, id == self.lastChosenH10Id {
                    self.h10State = .connected
                    self.refreshSourcesByConnectedDevices()
                } else {
                    // 若不是我们选中的 H10 或变为 nil：在非 connecting 状态下回退
                    if self.h10State != .connecting {
                        // 若扫描里仍能看到 H10，则回退到 discovered，否则 not_found
                        let hasH10 = pm.discovered.contains { $0.name.localizedCaseInsensitiveContains("h10") }
                        self.h10State = hasH10 ? .discovered : .not_found
                    }
                }
                
                if let id = id, id == self.lastChosenVerityId {
                    self.verityState = .connected
                    self.refreshSourcesByConnectedDevices()
                } else {
                    // 若不是我们选中的 verity 或变为 nil：在非 connecting 状态下回退
                    if self.verityState != .connecting {
                        // 若扫描里仍能看到 verity，则回退到 discovered，否则 not_found
                        let hasVerity = pm.discovered.contains { $0.name.localizedCaseInsensitiveContains("Verity") }
                        self.verityState = hasVerity ? .discovered : .not_found
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // 广播受试者信息
    func applyParticipant(pid: String, sessionID: String, broadcast: Bool = true) {
        let pidTrim = pid.trimmingCharacters(in: .whitespacesAndNewlines)
        let sidTrim = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pidTrim.isEmpty, !sidTrim.isEmpty else {
            print("[AppStore] applyParticipant: empty pid or session, skip")
            return
        }

        print("[AppStore] participant -> pid=\(pidTrim) session=\(sidTrim)")

        // 本地立即广播（不依赖开始采集），便于在 LabRecorder 中作为会话开端标注
        guard broadcast else { return }

        // 1) session_meta
        let now = Date().timeIntervalSince1970
        let meta = SessionMetaPacket(device: "app",
                                     t_device: now,
                                     seq: nil,
                                     pid: pidTrim,
                                     session: sidTrim)
        if let s = TelemetryEncoder.encodeToJSONString(meta) {
            UDPSenderService.shared.send(s)
        }

        // 2) marker（清晰地写入标注流）
        let label = "session_update: pid=\(pidTrim), session=\(sidTrim)"
        let marker = MarkerPacket(device: "app", t_device: now, seq: nil, label: label)
        if let s2 = TelemetryEncoder.encodeToJSONString(marker) {
            UDPSenderService.shared.send(s2)
        }
    }
    
    // --- UDP 全局信号处理 ---
    // 更新UDP目标
    func applyTarget(host: String, port: Int) {
        let p = (1...65535).contains(port) ? port : 9001
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        udpTarget = UdpTarget(host: h.isEmpty ? AppConfig.defaultUDPHost : h, port: p)
        print("[AppStore] target -> \(udpTarget.address)")

        // ★ 新增：写回 AppStorage 对应的键
        UserDefaults.standard.set(udpTarget.host, forKey: "udpHost")
        UserDefaults.standard.set(udpTarget.port, forKey: "udpPort")

        // 同步给两路 UDP（数据/标记）
        dataSender.update(host: udpTarget.host, port: UInt16(udpTarget.port))
        UDPSenderService.shared.update(host: udpTarget.host, port: udpTarget.port)
        
        if let lanKey = NetworkInfo.lanKeyForMemory() {
            let dict: [String: Any] = ["host": udpTarget.host, "port": udpTarget.port]
            UserDefaults.standard.set(dict, forKey: "lastTarget:\(lanKey)")
            print("[AppStore] remember target for \(lanKey) -> \(udpTarget.address)")
        }
    }
    
    // --- “标注”数据发送 ---
    func markStarted() {
        if !isCollecting { isCollecting = true }
        print("[AppStore] 收集数据 -> true")
    }

    func markStopped() {
        if isCollecting { isCollecting = false }
        print("[AppStore] 收集数据 -> false")
    }

    func markSent() {
        collectCount += 1
        lastSentAt = Date()
    }

    func pushError(_ message: String) {
        lastError = message
        print("[AppStore][ERROR] \(message)")
    }

    // 开新轮次时重置计数
    func resetSessionCounters() {
        collectCount = 0
        lastSentAt = nil
    }
    
    // --- 选择数据 ---
    /// 根据已连接设备刷新“可用数据源”
    func refreshSourcesByConnectedDevices() {
        var set = Set<DataSource>()
        if verityState == .connected { set.formUnion([.ppi, .ppg, .vhr]) }
        if h10State    == .connected { set.formUnion([.ecg, .hhr]) }
        activeSources = Array(set).sorted { $0.rawValue < $1.rawValue }
        print("[AppStore] activeSources -> \(activeSources.map { $0.title }.joined(separator: ","))")
        
        // 进入采集页时就能清晰看到有哪些可选数据类型
        let availNames = Array(self.availableSignals).map { $0.title }.sorted().joined(separator: ",")
        print("[Signals][Available] 可用数据 \(availNames)")
    }
    
    // 用户选择收集哪个数据
    func toggleSelect(_ kind: SignalKind) {
        if selectedSignals.contains(kind) {
            selectedSignals.remove(kind)
        } else {
            selectedSignals.insert(kind)
        }
        print("[Store] selectedSignals=\(selectedSignals.map{$0.title}.joined(separator: ","))")
        // 若正在采集，动态应用新的选择集合
        if isCollecting, let id = PolarManager.shared.connectedId {
            PolarManager.shared.applySelection(deviceId: id, kinds: selectedSignals)
        }

    }
    // --- 设备卡界面信息配置 ---
    /// 点击设备卡（仅当已连接时生效）：让采集页“点亮”数据源
    func tapDeviceCard(_ which: String) {
        switch which {
        case "verity":
            if verityConnected {
                // 已连接：点击即刷新可订阅数据源
                refreshSourcesByConnectedDevices()
                return
            }
            guard let id = bestVerityCandidateId() else {
                pushError("尚未发现 Verity，请确认已开启/在附近，且关闭 Polar Flow。")
                return
            }
            verityState = .connecting
            lastChosenVerityId = id
            print("[AppStore][Verity] connect -> \(id)")
            PolarManager.shared.connect(id: id)
        case "h10":
            //点击 H10 即发起连接”的实现
            if h10Connected {
                // 已连接：点击即刷新可订阅的数据源（维持你原有语义）
                refreshSourcesByConnectedDevices()
                return
            }
            // 未连接：发起连接
            guard let id = bestH10CandidateId() else {
                pushError("尚未发现 H10，请确认已佩戴/开启，且关闭 Polar Flow。")
                return
            }
            h10State = .connecting
            lastChosenH10Id = id
            print("[AppStore][H10] connect -> \(id)")
            PolarManager.shared.connect(id: id)
        default:
            break
        }
        refreshSourcesByConnectedDevices()
    }

    /// 调试：手动改状态（供 DebugView 用）
    func setVerityState(_ s: DeviceState) {
        verityState = s
        refreshSourcesByConnectedDevices()
    }

    func setH10State(_ s: DeviceState) {
        h10State = s
        refreshSourcesByConnectedDevices()
    }
    
    // 选一个最合适的 H10 设备（先按名称包含 H10 过滤，若无则退化为 RSSI 最大的任意设备）
    private func bestH10CandidateId() -> String? {
        let list = PolarManager.shared.discovered
        let h10s  = list.filter { $0.name.localizedCaseInsensitiveContains("h10") }
        let base  = h10s.isEmpty ? list : h10s
        let best  = base.max(by: { $0.rssi < $1.rssi })
        return best?.id
    }
    // 选一个最合适的 Verity 设备
    private func bestVerityCandidateId() -> String? {
        let list = PolarManager.shared.discovered
        // Verity 广播名通常包含 "Sense"；也兼容 "Verity"、"OH1"
        let verities = list.filter {
            let n = $0.name.lowercased()
            return n.contains("sense") || n.contains("verity") || n.contains("oh1")
        }
        let base = verities.isEmpty ? list : verities
        let best = base.max(by: { $0.rssi < $1.rssi })
        return best?.id
    }

    
    // --- 采集页面-当前采集状态栏配置信息 ---
    
    // --- 采集页面 ---
    func startCollect() {
        guard !isCollecting else { return }
        //trialID = trialID + 1
        markerCount = 0
        // 开新轮次时把计数清零，便于采集页显示
        collectCount = 0
        lastSentAt = nil

        sessionStart = Date()
        sessionStop  = nil
        isCollecting = true
        
        markerStep = -1
        baselineStart = nil; baselineAccum = 0
        stimStart     = nil; stimAccum     = 0
        intervStart   = nil; intervAccum   = 0

        print("[Store] startCollect trial=\(trialID) subject=\(subjectID ?? "—") signals=\(selectedSignals.map{$0.title}.joined(separator: ","))")
        
        // 应用当前选择：所选即采
        if let id = PolarManager.shared.connectedId {
            PolarManager.shared.applySelection(deviceId: id, kinds: selectedSignals)
        } else {
            print("[Store] startCollect: 未连接设备，跳过订阅")
        }
    }

    func stopCollect() {
        guard isCollecting else { return }
        isCollecting = false

        if let t = dataTimer {
            print("[Store] dataTimer invalidate -> \(Unmanaged.passUnretained(t).toOpaque())")
            t.invalidate()
        }
        dataTimer = nil
        sessionStop  = Date()
        // 结束前对仍在进行的阶段做结算
        let now = Date()
        if let t0 = baselineStart { baselineAccum += now.timeIntervalSince(t0); baselineStart = nil }
        if let t0 = stimStart     { stimAccum     += now.timeIntervalSince(t0); stimStart     = nil }
        if let t0 = intervStart   { intervAccum   += now.timeIntervalSince(t0); intervStart   = nil }


        let dur = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        print("[Store] stopCollect duration=\(String(format: "%.1f", dur))s markers=\(markerCount)")
        
        // ★ 关闭内置模拟
        stopSimLoop()
        // 停止所有订阅
        PolarManager.shared.stopAllStreams()

    }
    
    // 调试页“发送一次”也走总线，保持口径一致
    func sendOnceHeartbeat() {
        let ts = Date().timeIntervalSince1970
        let msg = #"{"type":"heartbeat","t":\#(ts)}"#
        dataSender.send(msg)
        markSent()
    }

    // --- 发送MARK ---
    // 把事件丢到 MarkerBus → UdpMarkerBridge
    func emitMarker(_ label: MarkerLabel) {
        // 复用我们之前做好的总线 → UDP 桥
        MarkerBus.shared.emit(label: label)
        // markerCount += 1 已经在UdpMarkerBridge中添加
        print("[Store] marker +=1 -> \(markerCount) label=\(label.rawValue)")
    }
    // 判断这个 label 是否可发（正在采集 + 恰好是“下一个”）
    func canEmit(_ label: MarkerLabel) -> Bool {
        return isCollecting && (markerAllowedNext == label)
    }
    // 带顺序校验的发标记（UI 调用这个）
    func emitMarkerInOrder(_ label: MarkerLabel) {
        guard canEmit(label) else {
            print("[Store][MARK][REJECT] not allowed next=\(markerAllowedNext?.rawValue ?? "nil"), got=\(label.rawValue), isCollecting=\(isCollecting)")
            return
        }

        // ADDED: 阶段计时的开始/结算（不改 markerStep 语义）
        let now = Date()
        switch label {
        case .baseline_start:
            // 开始“基线”
            if baselineStart == nil { baselineStart = now }

        case .stim_start:
            // 结算“基线”，开始“诱导”
            if let t0 = baselineStart { baselineAccum += now.timeIntervalSince(t0); baselineStart = nil }
            stimStart = now

        case .stim_end:
            // 结算“诱导”
            if let t0 = stimStart { stimAccum += now.timeIntervalSince(t0); stimStart = nil }

        case .intervention_start:
            // 开始“干预”
            if intervStart == nil { intervStart = now }

        case .intervention_end:
            // 结算“干预”
            if let t0 = intervStart { intervAccum += now.timeIntervalSince(t0); intervStart = nil }
        }

        // 发送（复用你原有流程）
        emitMarker(label)

        // 推进流程（你原有的语义保留）
        markerStep += 1
    }

    // --- 采集页面-时间格式化mm:ss ---
    func formatMMSS(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", s/60, s%60)
    }
    // 阶段耗时（已累计 + 如在计时则加上“至今”）
    func elapsedBaseline(_ now: Date = Date()) -> TimeInterval {
        baselineAccum + (baselineStart.map { now.timeIntervalSince($0) } ?? 0)
    }
    func elapsedStim(_ now: Date = Date()) -> TimeInterval {
        stimAccum + (stimStart.map { now.timeIntervalSince($0) } ?? 0)
    }
    func elapsedIntervention(_ now: Date = Date()) -> TimeInterval {
        intervAccum + (intervStart.map { now.timeIntervalSince($0) } ?? 0)
    }
    
    // 供 DebugView 显示与回填 IP
    func lastTargetForCurrentLAN() -> UdpTarget? {
        guard let lanKey = NetworkInfo.lanKeyForMemory(),
              let dict = UserDefaults.standard.dictionary(forKey: "lastTarget:\(lanKey)"),
              let host = dict["host"] as? String,
              let port = dict["port"] as? Int else { return nil }
        return UdpTarget(host: host, port: port)
    }

    func currentLANDescription() -> String {
        return NetworkInfo.lanDescription()
    }

    
    // 当前总用时（停止后保持不变）
    func elapsedSeconds(now: Date = Date()) -> TimeInterval {
        guard let start = sessionStart else { return 0 }
        let end = isCollecting ? now : (sessionStop ?? now)
        return end.timeIntervalSince(start)
    }

    private func stopSimLoop() {
        simTimer?.invalidate()
        simTimer = nil
        print("[Store] simLoop stopped")
    }


}

