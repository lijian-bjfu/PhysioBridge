//
//  ProgressLogViewModel.swift
//  PolarBridge
//
//  Created by lijian on 8/30/25.
//

import SwiftUI
import Combine

/// 行模型与 ProgressLogView 共用
struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}

/// 采集进度 ViewModel：
/// - 订阅 AppStore：isCollecting、markerStep、connected 设备
/// - 订阅 PolarManager：lastECGuV, lastPPG1, lastRrMs, lastPpiMs
/// - 固定每 2 秒产出 4 行 + 方正型分隔线；MARK 贯穿行；开始/结束虚线框
@MainActor
final class ProgressLogViewModel: ObservableObject {
    @Published var lines: [LogLine] = []

    private let store: AppStore
    private let pm: PolarManager
    private var bag = Set<AnyCancellable>()
    private var timer: AnyCancellable?

    // 最近值（没有新值则沿用）
    private var ecg_uV: Int?
    private var ppg1_au: Int?
    private var rr_ms: Int?
    private var ppi_ms: Int?
    
    // 按设备缓存 HR（原来数据为UInt8 统一转为 Int，便于显示/运算）
    private var lastHrByDevice: [String: Int] = [:]
    
    // 只显示用户选择的信号集合
    private var enabled: Set<SignalKind> = []

    // 打印用
    private var elapsedSec: Int = 0
    private let intervalSec: Int = 2
    private let separator = "-  -  -  -"

    // 追踪 marker 序号，避免重复
    private var lastMarkerStep: Int = -1

    init(store: AppStore, pm: PolarManager? = nil) {
        self.store = store
        self.pm = pm ?? PolarManager.shared
        bind()
    }
    deinit {
        timer?.cancel()
        bag.removeAll()
    }

    // 绑定 AppStore/PM 的发布者
    private func bind() {
        // 采集开始/停止 → 开关计时器与头尾框
        store.$isCollecting
            .removeDuplicates()
            .sink { [weak self] collecting in
                guard let self = self else { return }
                if collecting {
                    self.startSession()
                } else {
                    self.stopSession()
                }
            }
            .store(in: &bag)

        // MARK 顺序推进 → 打印中文标记行
        store.$markerStep
            .removeDuplicates()
            .sink { [weak self] step in
                guard let self = self else { return }
                guard step >= 0, step != self.lastMarkerStep else { return }
                self.lastMarkerStep = step
                // 显示 实验阶段 Mark 分割线
                let label = self.labelText(for: self.store.markerSequence[step])
                self.append("------ \(label) ------", color: .cyan)
            }
            .store(in: &bag)
        
        store.markerSeq.emitCustomMarker
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                guard let self = self else { return }
                // 显示 实验阶段 Mark 分割线
                self.append("------ \(name) ------", color: .cyan)
            }
            .store(in: &bag)

        // 最新数值：PM → 本地缓存（2 秒 tick 时读取）
        pm.$lastECGuV
            .sink { [weak self] v in self?.ecg_uV = v }
            .store(in: &bag)
        
        pm.$lastHrByDevice
            .map { dict in dict.mapValues(Int.init) } // 转换元数据 UInt8 -> Int
            .sink { [weak self] dict in self?.lastHrByDevice = dict }
            .store(in: &bag)

        pm.$lastRrMs
            .map { $0.last }
            .sink { [weak self] v in self?.rr_ms = v }
            .store(in: &bag)
        
        pm.$lastPPG1
            .sink { [weak self] v in self?.ppg1_au = v }
            .store(in: &bag)

        pm.$lastPpiMs
            .sink { [weak self] v in self?.ppi_ms = v }
            .store(in: &bag)
        
        // 订阅用户当前选择作为过滤器
        store.$selectedSignals
            .removeDuplicates()
            .sink { [weak self] s in self?.enabled = s }
            .store(in: &bag)
    }

    private func startSession() {
        lines.removeAll()
        elapsedSec = 0
        lastMarkerStep = -1

        // 头部虚线框与“开始采集(设备)”
        append(separator)
        append(" 开 始 采 集 ", color: .green)
        append(separator)
        if pm.connectedH10Id != nil { append("[\(ts(0))]  开始采集 (H10)") }
        if pm.connectedVerityId != nil { append("[\(ts(0))]  开始采集 (Verity)") }
        append(separator, dim: true)

        // 固定 2 秒节拍
        timer?.cancel()
        timer = Timer
            .publish(every: TimeInterval(intervalSec), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickOnce() }
    }

    private func stopSession() {
        timer?.cancel()
        timer = nil
        append(separator)
        append(" 采 集 结 束 ", color: .green)
        append(separator)
    }

    // 获取用户当前选择的信号集
    private func want(_ k: SignalKind) -> Bool { enabled.contains(k) }
    
    private func tickOnce() {
        elapsedSec += intervalSec
        let t = ts(elapsedSec)

        // H10 / Verity 采样显示（合并 HR；ECG 暂时关闭）
        // ECG（暂时关闭，保留代码以便后续恢复）
        /*
        if want(.ecg) {
            append("[\(t)]  ECG   \(ecg_uV.map { "\($0) uV" } ?? "— uV")")
        }
        */

        // RR
        if want(.rr) {
            append("[\(t)]  RR    \(rr_ms.map { "\($0) ms" } ?? "— ms")")
        }

        // HR（合并显示逻辑）：双设备时显示 H10；单设备时显示该设备；否则显示占位
        let hrH10: Int? = pm.connectedH10Id.flatMap { lastHrByDevice[$0] }
        let hrVerity: Int? = pm.connectedVerityId.flatMap { lastHrByDevice[$0] }
        let primaryHR: Int? = hrH10 ?? hrVerity

        if want(.hhr) || want(.vhr) {
            let s = primaryHR.map { "\($0) bpm" } ?? "— bpm"
            append("[\(t)]  HR         \(s)")
        }

        // PPI
        if want(.ppi) {
            append("[\(t)]  PPI   \(ppi_ms.map { "\($0) ms" } ?? "— ms")")
        }
        // ppg
        if want(.ppg) {
            append("[\(t)]  PPG1  \(ppg1_au.map { "\($0)" } ?? "—") a.u.")
        }
        
        append(separator, dim: true)
        // 环形缓冲 200
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }

    // MARK: - 文本与工具

    private func labelText(for m: MarkerLabel) -> String {
        switch m {
        case .baseline_start:     return "基线_开始"
        case .stim_start:         return "诱导_开始"
        case .stim_end:           return "诱导_结束"
        case .intervention_start: return "干预_开始"
        case .intervention_end:   return "干预_结束"
        case .stop:               return "停止采集"
        }
    }

    private func append(_ text: String, color: Color = .green, dim: Bool = false) {
        let c = dim ? color.opacity(0.35) : color
        lines.append(LogLine(text: text, color: c))
    }

    private func ts(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%02d:%02d.000", m, s)
    }
}
