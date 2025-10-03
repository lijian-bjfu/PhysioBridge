//
//  AppStore.swift
//  PolarBridge
//
//  集中管理全局状态（UI 与服务共享的“单一真相”）；
//  现在支持 H10 与 Verity 双设备“并行连接/断开+各自订阅”。
//  外部可观察字段尽量保持不变，减少改动面。
//  2025-08 - multi-device refactor
//

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
        case .vhr: return "VHR"
        case .hhr: return "HHR"
        case .vacc: return "VACC"
        case .hacc: return "HACC"
        }
    }
    
    /// 一个系统图标名，后面 DataPill 可以用
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
        case .rr, .ppi: return "ms"
        case .ecg:      return "μV"
        case .ppg:      return "a.u."
        case .vhr, .hhr:return "bpm"
        case .vacc, .hacc: return "mG"
        }
    }
    var defaultFs: Int? {
        switch self {
        case .ecg: return 130
        case .hacc: return 50
        default:   return nil
        }
    }
    var defaultRangeG: Int? {
        switch self {
        case .hacc: return 4
        default:    return nil
        }
    }
    var shortDesc: String {
        switch self {
        case .rr:    return "相邻心搏间期"
        case .ppi:   return "心搏间期（光电测得）"
        case .ppg:   return "光体积脉搏波"
        case .ecg:   return "心电微伏采样"
        case .vhr:   return "每秒心率（Verity）"
        case .hhr:   return "每秒心率（H10）"
        case .vacc:  return "三轴加速度（Verity）"
        case .hacc:  return "三轴加速度（H10）"
        }
    }
}

// 设备状态
enum DeviceStatus: String, Codable { case unknown, available, connected }

// UDP 目标
struct UdpTarget: Codable, Equatable {
    var host: String
    var port: Int
    var address: String { "\(host):\(port)" }
    var isValid: Bool { !host.isEmpty && (1...65535).contains(port) }
}

// 切包统计结构体
struct CapStats {
    var count: Int = 0
    var minBytes: Int = .max
    var maxBytes: Int = 0
    var sumBytes: Int = 0

    var avgBytes: Double {
        count > 0 ? Double(sumBytes) / Double(count) : 0
    }

    mutating func add(bytes: Int) {
        count += 1
        minBytes = min(minBytes, bytes)
        maxBytes = max(maxBytes, bytes)
        sumBytes += bytes
    }

    static let empty = CapStats()
    var isEmpty: Bool { count == 0 }
}

// MARK: - AppStore

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    // MARK: 持久与会话态
    private var cancellables = Set<AnyCancellable>()

    // 记住最近一次“用户点选连接”的目标（只用于把‘正在连接’状态对上号）
    private var lastChosenH10Id: String? = nil
    private var lastChosenVerityId: String? = nil

    // 是否启用模拟（保留）
    @Published var simulateData: Bool = false
    private var simTimer: Timer?

    // 发送与目标
    @Published var udpTarget = UdpTarget(host: AppConfig.defaultUDPHost, port: AppConfig.defaultUDPPort)
    private var dataSender = UdpSender(host: AppConfig.defaultUDPHost, port: UInt16(AppConfig.defaultUDPPort))
    @Published var dataTimer: Timer?

    // 采集状态
    @Published var isCollecting: Bool = false
    @Published var lastError: String? = nil
    @Published var lastSentAt: Date?
    @Published var subjectID: String? = UserDefaults.standard.string(forKey: "subjectID")
    @Published var trialID: String = UserDefaults.standard.string(forKey: "trialID") ?? "0"

    @Published var markerCount: Int = 0
    
    // 切包统计数据
    @Published private(set) var capStats: CapStats = .empty

    // 设备状态（UI 读）
    @Published var verityState: DeviceState = .not_found
    @Published var h10State: DeviceState    = .not_found
    var verityConnected: Bool { verityState == .connected }
    var h10Connected:    Bool { h10State    == .connected }
    /// 派生：是否存在任一已连接设备（Publisher，不是多余状态）
    var devicePresence: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest($h10State, $verityState)
            .map { $0 == .connected || $1 == .connected }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    // 对外发布的、当前已连接设备的完整信息
    @Published private(set) var connectedDeviceInfo: PolarManager.Discovered? = nil

    // 当前“点亮”的数据源（采集页用）
    @Published var activeSources: [DataSource] = []

    /// 通过设备连接状态“推导”的可订阅集合
    var availableSignals: Set<SignalKind> {
        var s: Set<SignalKind> = []
        if verityConnected { s.formUnion([.ppi, .ppg, .vhr, .vacc]) }
        if h10Connected    { s.formUnion([.ecg, .hhr, .rr, .hacc]) }
        return s
    }

    // 采集页“用户勾选”的集合（两台设备共享这一组选择；执行时按设备拆分）
    @Published var selectedSignals: Set<SignalKind> = []
    
    // 设置页，用户选择“开启数据大小限制”开关激活
    private var cappedable: Bool { FeatureFlags.cappedTxEnabled }

    // 计时
    @Published var sessionStart: Date? = nil
    @Published var sessionStop: Date?  = nil

    // 标记顺序控制
    let markerSequence: [MarkerLabel] = [
        .baseline_start, .stim_start, .stim_end, .intervention_start, .intervention_end
    ]
    @Published private(set) var markerStep: Int = -1
    var markerActive: MarkerLabel? {
        guard markerStep >= 0 && markerStep < markerSequence.count else { return nil }
        return markerSequence[markerStep]
    }
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
    private var customEvents: [Date] = []
    var customEventCount: Int { customEvents.count }
    // MARK: - debug
    private var verbose: Bool { FeatureFlags.consoleVerbose }

    #if DEBUG
    private(set) var currentOpID: String = ""
    @MainActor
    private(set) var lastApplyReason: String = ""
    #endif

    // MARK: - init
    private init() {
        bindPolar()
        _ = UdpMarkerBridge.shared
        
        // ★ 启动即同步 UDP 目标（数值流），避免“没点设置就发到默认地址”
        if let last = lastTargetForCurrentLAN() {
            // 这里会顺带更新 UDPSenderService.shared
            applyTarget(host: last.host, port: last.port)
        } else {
            // 即使没有历史，也要把当前默认目标喂给 UDPSenderService
            UDPSenderService.shared.update(host: udpTarget.host, port: udpTarget.port)
        }
    }

    // MARK: - Polar 绑定
    /// 绑定 Verity 与 H10 设备
    private func bindPolar() {
        let pm = PolarManager.shared

        // 扫描发现 → 更新“可发现/未发现”，已连接则不影响
        pm.$discovered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                guard let self = self else { return }
                let hasH10 = list.contains { $0.name.localizedCaseInsensitiveContains("h10") }
                let hasVerity = list.contains { n in
                    let s = n.name.lowercased()
                    return s.contains("sense") || s.contains("verity") || s.contains("oh1")
                }
                if self.h10State != .connected {
                    self.h10State = hasH10 ? .discovered : .not_found
                }
                if self.verityState != .connected {
                    self.verityState = hasVerity ? .discovered : .not_found
                }
            }
            .store(in: &cancellables)

        // “正在连接”的闪烁图标（不区分设备）
        pm.$connectingId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self = self else { return }
                if let id, id == self.lastChosenH10Id  { self.h10State = .connecting }
                if let id, id == self.lastChosenVerityId { self.verityState = .connecting }
            }
            .store(in: &cancellables)

        // H10 连接/断开
        pm.$connectedH10Id
            .combineLatest(pm.$connectedVerityId, pm.$discovered)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] h10Id, verityId, discoveredList in
                guard let self = self else { return }
                
                // 优先显示 H10 的信息
                if let id = h10Id {
                    self.h10State = .connected
                    self.connectedDeviceInfo = discoveredList.first { $0.id == id }
                } else {
                    // 回退：扫描里有就回 discovered，否则 not_found
                    let has = pm.discovered.contains { $0.name.localizedCaseInsensitiveContains("h10") }
                    if self.h10State != .connecting {
                        self.h10State = has ? .discovered : .not_found
                    }
                }
                
                // 如果 H10 未连接，则显示 Verity 的信息
                if let id = verityId {
                    self.connectedDeviceInfo = discoveredList.first { $0.id == id }
                    return
                }
                // 如果两个设备都未连接
                self.connectedDeviceInfo = nil
                
                
                self.refreshSourcesByConnectedDevices()
            }
            .store(in: &cancellables)

        // Verity 连接/断开
        pm.$connectedVerityId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self = self else { return }
                if let _ = id {
                    self.verityState = .connected
                } else {
                    let has = pm.discovered.contains {
                        let n = $0.name.lowercased()
                        return n.contains("sense") || n.contains("verity") || n.contains("oh1")
                    }
                    if self.verityState != .connecting {
                        self.verityState = has ? .discovered : .not_found
                    }
                }
                self.refreshSourcesByConnectedDevices()
            }
            .store(in: &cancellables)
        
        // 切包统计：仅在采集中且开启“限制数据大小传输”时累计
        pm.capEvents
            .filter { [weak self] _ in
                guard let self = self else { return false }
                return self.isCollecting && self.cappedable
            }
            .map(\.bytes)                          // 只取字节数
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bytes in
                self?.capStats.add(bytes: bytes)
            }
            .store(in: &cancellables)

    }

    // MARK: - UDP 目标
    // 更新UDP目标
    func applyTarget(host: String, port: Int) {
        let p = (1...65535).contains(port) ? port : 9001
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        udpTarget = UdpTarget(host: h.isEmpty ? AppConfig.defaultUDPHost : h, port: p)
        print("[AppStore] target -> \(udpTarget.address)")
        
        // 写回 AppStorage 对应的键
        UserDefaults.standard.set(udpTarget.host, forKey: "udpHost")
        UserDefaults.standard.set(udpTarget.port, forKey: "udpPort")
        
        /// // 同步给两路 UDP（数据/标记）
        // dataSender.update(host: udpTarget.host, port: UInt16(udpTarget.port))
        UDPSenderService.shared.update(host: udpTarget.host, port: udpTarget.port)

        if let lanKey = NetworkInfo.lanKeyForMemory() {
            let dict: [String: Any] = ["host": udpTarget.host, "port": udpTarget.port]
            UserDefaults.standard.set(dict, forKey: "lastTarget:\(lanKey)")
            print("[AppStore] remember target for \(lanKey) -> \(udpTarget.address)")
        }
    }

    // MARK: - 设备卡片点击：连接/断开切换
    func tapDeviceCard(_ which: String) {
        switch which {
        case "verity":
            let pm = PolarManager.shared
            if verityConnected, let id = pm.connectedVerityId {
                print("[AppStore][Verity] disconnect -> \(id)")
                pm.disconnect(id: id)
                return
            }
            guard let id = bestVerityCandidateId() else {
                pushError("尚未发现 Verity，请确认已开启/在附近，且关闭 Polar Flow。")
                return
            }
            lastChosenVerityId = id
            verityState = .connecting
            print("[AppStore][Verity] connect -> \(id)")
            pm.connect(id: id)

        case "h10":
            let pm = PolarManager.shared
            if h10Connected, let id = pm.connectedH10Id {
                print("[AppStore][H10] disconnect -> \(id)")
                pm.disconnect(id: id)
                return
            }
            guard let id = bestH10CandidateId() else {
                pushError("尚未发现 H10，请确认已佩戴/开启，且关闭 Polar Flow。")
                return
            }
            lastChosenH10Id = id
            h10State = .connecting
            print("[AppStore][H10] connect -> \(id)")
            pm.connect(id: id)

        default:
            break
        }
        refreshSourcesByConnectedDevices()
    }

    // MARK: - 可用数据源刷新
    func refreshSourcesByConnectedDevices() {
        var set = Set<DataSource>()
        if verityConnected { set.formUnion([.ppi, .ppg, .vhr, .vacc]) }
        if h10Connected    { set.formUnion([.ecg, .hhr, .rr, .hacc]) }
        activeSources = Array(set).sorted { $0.rawValue < $1.rawValue }
        let availNames = Array(self.availableSignals).map { $0.title }.sorted().joined(separator: ",")
        print("[AppStore] activeSources -> \(activeSources.map { $0.title }.joined(separator: ","))")
        print("[Signals][Available] 可用数据 \(availNames)")
    }

    // MARK: - 采集选择（按设备拆分后下发）
    func toggleSelect(_ kind: SignalKind) {
        if selectedSignals.contains(kind) { selectedSignals.remove(kind) }
        else { selectedSignals.insert(kind) }
        print("[Store] selectedSignals=\(selectedSignals.map{$0.title}.joined(separator: ","))")

        guard isCollecting else { return }
        // MARK: debug 数据溯源5-调用位置2
        #if DEBUG
        if self.verbose {
            print("[Store] DISPATCH applySelection (reason=toggleSelect kind=\(kind.title))")
        }
        #endif
        applySelectionToConnectedDevices()
    }

    private func kindsForVerity(from all: Set<SignalKind>) -> Set<SignalKind> {
        all.intersection([.ppi, .ppg, .vhr, .vacc])
    }
    private func kindsForH10(from all: Set<SignalKind>) -> Set<SignalKind> {
        all.intersection([.ecg, .hhr, .rr, .hacc])
    }

    private func applySelectionToConnectedDevices() {
        let pm = PolarManager.shared
        let selV = kindsForVerity(from: selectedSignals)
        let selH = kindsForH10(from: selectedSignals)
        
        // MARK: debug 数据溯源3-检查信号发给谁、发什么
        #if DEBUG
        if self.verbose {
            print("[Store] applySelectionToConnectedDevices verity=\(selV.map{$0.title}) h10=\(selH.map{$0.title})")
        }
        #endif

        if let id = pm.connectedVerityId, !selV.isEmpty {
            pm.applySelection(deviceId: id, kinds: selV)
        } else if let id = pm.connectedVerityId {
            // 空集合也要通知，用于停流
            pm.applySelection(deviceId: id, kinds: [])
        }
        if let id = pm.connectedH10Id, !selH.isEmpty {
            pm.applySelection(deviceId: id, kinds: selH)
        } else if let id = pm.connectedH10Id {
            pm.applySelection(deviceId: id, kinds: [])
        }
    }

    // MARK: - 开始采集
    func startCollect() {
        guard !isCollecting else { return }
        
        if self.cappedable {
            capStats = .empty
        }
        
        // MARK: debug 数据溯源
        #if DEBUG
        if self.verbose {
            currentOpID = "op\(UInt64(Date().timeIntervalSince1970 * 1000))"
            print("[Store] DISPATCH applySelection (reason=startCollect)")
            lastApplyReason = "startCollect"
        }
        #endif
        
        markerCount = 0
        lastSentAt = nil

        sessionStart = Date()
        sessionStop  = nil
        isCollecting = true

        markerStep = -1
        customEvents.removeAll()
        baselineStart = nil; baselineAccum = 0
        stimStart     = nil; stimAccum     = 0
        intervStart   = nil; intervAccum   = 0

        print("[Store] startCollect trial=\(trialID) subject=\(subjectID ?? "—") signals=\(selectedSignals.map{$0.title}.joined(separator: ","))")

        // ★ 关键：把当前选择分派到“各自设备”
        applySelectionToConnectedDevices()
    }

    func stopCollect() {
        guard isCollecting else { return }
        
        // 先发一个“停止采集”标记
        MarkerBus.shared.emit(label: .stop, note: "user_tapped_stop")
        
        isCollecting = false

        dataTimer?.invalidate(); dataTimer = nil
        sessionStop  = Date()

        let now = Date()
        if let t0 = baselineStart { baselineAccum += now.timeIntervalSince(t0); baselineStart = nil }
        if let t0 = stimStart     { stimAccum     += now.timeIntervalSince(t0); stimStart     = nil }
        if let t0 = intervStart   { intervAccum   += now.timeIntervalSince(t0); intervStart   = nil }

        let dur = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        print("[Store] stopCollect duration=\(String(format: "%.1f", dur))s markers=\(markerCount)")

        stopSimLoop()
        PolarManager.shared.stopAllStreams()
    }

    // MARK: - 标记发送
    func emitMarker(_ label: MarkerLabel) {
        MarkerBus.shared.emit(label: label)
        print("[Store] marker +=1 -> \(markerCount) label=\(label.rawValue)")
    }
    func canEmit(_ label: MarkerLabel) -> Bool {
        guard isCollecting else { return false }
        switch label {
        case .custom_events, .stop:
            return true                    // 采集中随时放行
        default:
            return markerAllowedNext == label
        }
    }
    func emitMarkerInOrder(_ label: MarkerLabel) {
        guard canEmit(label) else {
            print("[Store][MARK][REJECT] not allowed next=\(markerAllowedNext?.rawValue ?? "nil"), got=\(label.rawValue), isCollecting=\(isCollecting)")
            return
        }
        
        if label == .stop {
            // 内部会先发 STOP 标记到 UDP/LSL，再停流
            stopCollect()
            return
        }
        
        let now = Date()
        switch label {
        case .baseline_start:
            if baselineStart == nil { baselineStart = now }
        case .stim_start:
            if let t0 = baselineStart { baselineAccum += now.timeIntervalSince(t0); baselineStart = nil }
            stimStart = now
        case .stim_end:
            if let t0 = stimStart { stimAccum += now.timeIntervalSince(t0); stimStart = nil }
        case .intervention_start:
            if intervStart == nil { intervStart = now }
        case .intervention_end:
            if let t0 = intervStart { intervAccum += now.timeIntervalSince(t0); intervStart = nil }
        case .stop:
            break
        case .custom_events:
            customEvents.append(now)
        }
        emitMarker(label)
        
        // 自定义事件标记不参与推进阶段序号，也不改变当前active
        if label != .custom_events {
            markerStep += 1
        }
    }
    // MARK: - 更新被试信息
    func applyParticipant(pid: String, sessionID: String, broadcast: Bool = true) {
        let pidTrim = pid.trimmingCharacters(in: .whitespacesAndNewlines)
        let sidTrim = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pidTrim.isEmpty, !sidTrim.isEmpty else {
            print("[AppStore] applyParticipant: empty pid or session, skip")
            return
        }
        
        // 1) 先更新“单一真相”，无论广播与否
        subjectID = pidTrim
        trialID   = sidTrim
        UserDefaults.standard.set(pidTrim, forKey: "subjectID")
        UserDefaults.standard.set(sidTrim, forKey: "trialID")

        print("[AppStore] participant -> pid=\(pidTrim) session=\(sidTrim)")

        // 本地立即广播（不依赖开始采集），便于在 LabRecorder 中作为会话开端标注
        guard broadcast else { return }

        // 2) session_meta
        let now = Date().timeIntervalSince1970
        let meta = SessionMetaPacket(device: "app",
                                     t_device: now,
                                     seq: nil,
                                     pid: pidTrim,
                                     session: sidTrim)
        if let s = TelemetryEncoder.encodeToJSONString(meta) {
            UDPSenderService.shared.send(s)
        }

        // 2.2) marker（清晰地写入标注流）
        let label = "session_update: pid=\(pidTrim), session=\(sidTrim)"
        let marker = MarkerPacket(device: "app", t_device: now, seq: nil, label: label)
        if let s2 = TelemetryEncoder.encodeToJSONString(marker) {
            UDPSenderService.shared.send(s2)
        }
    }

    // MARK: - 杂项工具
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
    
    func pushError(_ message: String) {
        lastError = message
        print("[AppStore][ERROR] \(message)")
    }

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

    private func bestH10CandidateId() -> String? {
        let list = PolarManager.shared.discovered
        let h10s  = list.filter { $0.name.localizedCaseInsensitiveContains("h10") }
        let base  = h10s.isEmpty ? list : h10s
        let best  = base.max(by: { $0.rssi < $1.rssi })
        return best?.id
    }

    private func bestVerityCandidateId() -> String? {
        let list = PolarManager.shared.discovered
        let verities = list.filter {
            let n = $0.name.lowercased()
            return n.contains("sense") || n.contains("verity") || n.contains("oh1")
        }
        let base = verities.isEmpty ? list : verities
        let best = base.max(by: { $0.rssi < $1.rssi })
        return best?.id
    }

}

