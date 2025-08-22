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
    case ppi, ppg, hr, ecg
    var id: String { rawValue }

    /// UI 上显示的中文名
    var title: String {
        switch self {
        case .ppi: return "PPI"
        case .ppg: return "PPG"
        case .hr:  return "HR"
        case .ecg: return "ECG"
        }
    }

    /// 可选：一个系统图标名，后面 DataPill 可以用
    var sfSymbol: String {
        switch self {
        case .ppi: return "bolt.heart"
        case .ppg: return "waveform.path.ecg"
        case .hr:  return "heart.fill"
        case .ecg: return "waveform"
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
    
    // 是否启用内置模拟数据（先默认 true，等接入 Polar 后可关掉）
    @Published var simulateData: Bool = true
    // 内部记录定时器（仅在 simulateData 为 true 时启用）
    private var simTimer: Timer?

    // --- 发送与目标 ---
    @Published var udpTarget = UdpTarget(host: "127.0.0.1", port: 9001)
    // 数据发送器（用于心跳/数据流）；与“标记”分离
    private var dataSender = UdpSender(host: "127.0.0.1", port: 9001)
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
        if verityState == .connected { s.formUnion([.ppi, .ppg, .hr]) }
        if h10State    == .connected { s.formUnion([.ecg, .hr]) }
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

    private init() {}

    // 改目标（做简单校验）
    func applyTarget(host: String, port: Int) {
        let p = (1...65535).contains(port) ? port : 9001
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        udpTarget = UdpTarget(host: h.isEmpty ? "127.0.0.1" : h, port: p)
        print("[AppStore] target -> \(udpTarget.address)")
        
        // 同步给两路 UDP（数据/标记）
        dataSender.update(host: udpTarget.host, port: UInt16(udpTarget.port))
        UDPSenderService.shared.update(host: udpTarget.host, port: udpTarget.port)
    }
    

    // --- UDP 全局信号处理 ---
    /// 标记UDP开始/停止/成功发送/错误
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
        if verityState == .connected { set.formUnion([.ppi, .ppg, .hr]) }
        if h10State    == .connected { set.formUnion([.ecg, .hr]) }
        activeSources = Array(set).sorted { $0.rawValue < $1.rawValue }
        print("[AppStore] activeSources -> \(activeSources.map { $0.title }.joined(separator: ","))")
    }
    
    // 用户选择收集哪个数据
    func toggleSelect(_ kind: SignalKind) {
        if selectedSignals.contains(kind) {
            selectedSignals.remove(kind)
        } else {
            selectedSignals.insert(kind)
        }
        print("[Store] selectedSignals=\(selectedSignals.map{$0.title}.joined(separator: ","))")
    }
    // --- 设备卡界面信息配置 ---
    /// 点击设备卡（仅当已连接时生效）：让采集页“点亮”数据源
    func tapDeviceCard(_ which: String) {
        switch which {
        case "verity":
            guard verityConnected else { return }
        case "h10":
            guard h10Connected else { return }
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

        // 开启 1Hz 心跳（模拟数据流）
        if dataTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                // ★ 在闭包里切回主线程，再访问 AppStore（@MainActor）
                Task { @MainActor in
                    guard let self = self, self.isCollecting else { return }
                    let ts = Date().timeIntervalSince1970
                    let msg = #"{"type":"heartbeat","t":\#(ts)}"#
                    self.dataSender.send(msg)
                    self.markSent()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            dataTimer = t
            print("[Store] dataTimer scheduled -> \(Unmanaged.passUnretained(t).toOpaque())")
        }
        // 启动内置模拟数据（仅在开关为 true 时）
        if simulateData { startSimLoop() }
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
    
    // 当前总用时（停止后保持不变）
    func elapsedSeconds(now: Date = Date()) -> TimeInterval {
        guard let start = sessionStart else { return 0 }
        let end = isCollecting ? now : (sessionStop ?? now)
        return end.timeIntervalSince(start)
    }
    
    // === 两个私有方法：启动/停止模拟收集过程的循环 ===
    private func startSimLoop() {
        guard simTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let ts = Date().timeIntervalSince1970
            let payload = #"{"type":"heartbeat","t":\#(ts)}"#
            // 统一通过 UDPSenderService 发
            UDPSenderService.shared.send(payload)
            // 更新全局计数（采集状态 A 区会联动）
            Task { @MainActor in
                self.markSent()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        simTimer = t
        print("[Store] simLoop started")
    }

    private func stopSimLoop() {
        simTimer?.invalidate()
        simTimer = nil
        print("[Store] simLoop stopped")
    }


}

