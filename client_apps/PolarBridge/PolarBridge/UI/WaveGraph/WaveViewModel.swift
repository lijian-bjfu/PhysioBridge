//
//  WaveViewModel.swift
//  PolarBridge
//
//  Created by lijian on 10/29/25.
//

import SwiftUI
import Combine

// MARK: - 轻量环形缓冲（线程安全：主线程使用；UI 丢帧不阻塞采集）
final class WaveRingBuffer {
    private var times: [Double]
    private var vals:  [Float]
    private var head = 0
    private var count = 0
    private let capMask: Int  // 容量需为 2 的幂

    // 环形缓冲区的容量指数，而是2 的 13 次方（2^13）
    // 带安全余量的通用默认值，覆盖你当前显示窗口的最高采样率信号而不必频繁覆盖：
    // ECG：H10 常见 130 Hz。8–10 s 小窗需要大约 1300 点。
    // 这样可以保证容量始终是 2 的幂，后面的索引计算就能用按位与代替取模
    init(capacityPowerOf2: Int = 13) { // 2^13 = 8192
        let cap = 1 << capacityPowerOf2
        self.times = [Double](repeating: 0, count: cap)
        self.vals  = [Float](repeating: 0, count: cap)
        self.capMask = cap - 1
    }

    @inline(__always)
    private func idx(_ i: Int) -> Int { (head + i) & capMask }

    func append(ts: Double, v: Float) {
        if count < times.count {
            times[idx(count)] = ts
            vals[idx(count)]  = v
            count += 1
        } else {
            // 覆盖最老值，推进 head
            times[head] = ts
            vals[head]  = v
            head = (head + 1) & capMask
        }
    }

    /// 返回 [now - windowSec, now] 的快照（拷贝后只读，避免与追加竞争）
    func snapshot(windowSec: Double, now: Double) -> ([Double], [Float]) {
        guard count > 0 else { return ([], []) }
        let tEnd = times[idx(count - 1)]
        // 优先使用传入 now；如果 now 较旧，仍以 now 为准，保证画面一致
        let right = min(now, tEnd)
        let left  = right - windowSec

        // 二分查找左边界（在环内做线性回退也可，这里简化为线性，数据量很小）
        var outT = [Double](); outT.reserveCapacity(count)
        var outV = [Float]();  outV.reserveCapacity(count)
        for i in 0..<count {
            let j = idx(i)
            let tt = times[j]
            if tt >= left && tt <= right {
                outT.append(tt)
                outV.append(vals[j])
            }
        }
        return (outT, outV)
    }
}

// MARK: - 配置与信号枚举
struct WaveConfig {
    var showHR   = true   // 常开
    var showECG  = false  // 仅 H10 且 QA 时开
    var showPPG  = false  // 仅 Verity 且 QA 时开
    var showPPI  = false  // 仅 Verity 且 QA 时开

    var winHR:  Double = 60   // 30–60 s 走线窗口
    var winECG: Double = 8    // 6–10 s 小窗
    var winPPG: Double = 8
    var winPPI: Double = 120  // 散点更长
    var maxPointsPerTrack = 600
}

@MainActor
final class WaveViewModel: ObservableObject {
    // 对外：开关与窗口配置（UI 双向绑定）
    @Published var config = WaveConfig()

    // 设备可用性（决定显示哪些开关）
    @Published private(set) var hasH10 = false
    @Published private(set) var hasVerity = false

    // 缓冲：HR 走线、ECG 波形、PPG 波形、PPI 散点
    private let hrBuf   = WaveRingBuffer()
    private let ecgBuf  = WaveRingBuffer()
    private let ppgBuf  = WaveRingBuffer()
    private let ppiBuf  = WaveRingBuffer()

    // PPG 去趋势 AC（百分比）
    private let ppgACBuf = WaveRingBuffer()
    private var ppgACBaseline: RunningQuantile? = nil // 近似中值（低计算量）
    private let ppgACWindowSec: Double = 1.5          // 1–2 s 去趋势窗

    // MARK: - PPI 逻辑时间轴锚点（用于把逐拍事件映射到“自然时间”）
    private var ppiLogicClock: Double?   // 秒（TimeInterval）
    private var ppiLastMs: Int?

    // 订阅
    private var bag = Set<AnyCancellable>()

    // 依赖
    private let pm: PolarManager

    init(pm: PolarManager) {
        self.pm = pm
        bindDevices()
        bindSignals()
    }

    // MARK: - 设备状态绑定：决定默认开关逻辑
    private func bindDevices() {
        pm.$connectedH10Id
            .combineLatest(pm.$connectedVerityId)
            .sink { [weak self] h10, vry in
                guard let self else { return }
                self.hasH10 = (h10 != nil)
                self.hasVerity = (vry != nil)

                // 根据你确认的规则设置“默认开关”（只在进入场景/设备变化时影响）
                // 仅 H10：HR 打开，ECG 关闭
                // 仅 Verity：HR 打开，PPI/PPG 关闭
                // H10+Verity：保留除 Verity HR 外的其余开关，HR 打开，其余关闭
                var cfg = self.config
                cfg.showHR  = true
                cfg.showECG = self.hasH10 ? false : false
                cfg.showPPG = false
                cfg.showPPI = false
                self.config = cfg
            }
            .store(in: &bag)
    }

    // MARK: - 信号绑定
    private func bindSignals() {
        // HR（H10 优先；若仅 Verity 则取 Verity）
        pm.$lastHrByDevice
            .combineLatest(pm.$connectedH10Id, pm.$connectedVerityId)
            .compactMap { dict, h10, vry -> Int? in
                if let h10, let v = dict[h10] { return Int(v) }
                if let vry, let v = dict[vry] { return Int(v) }
                return nil
            }
            // .removeDuplicates() 避免去重，0.5秒采样，让 hr 显示更顺滑
            .throttle(for: .seconds(0.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] bpm in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.hrBuf.append(ts: now, v: Float(bpm))
            }
            .store(in: &bag)

        // ECG（仅用于 QA 小窗；末样本）
        pm.$lastECGuV
            .compactMap { $0 }
            .sink { [weak self] uV in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.ecgBuf.append(ts: now, v: Float(uV))
            }
            .store(in: &bag)

        // PPG（仅用于 QA 小窗；末样本）
        pm.$lastPPG1
            .compactMap { $0 }
            .sink { [weak self] au in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.ppgBuf.append(ts: now, v: Float(au))
            }
            .store(in: &bag)

        // PPG → 去趋势 AC 百分比（用于“血量波动(%)”视图）
        pm.$lastPPG1
            .sink { [weak self] auOpt in
                guard let self = self, let au = auOpt else { return }
                let ts = CACurrentMediaTime()

                // 初始化/更新近似中值基线（抗尖峰，计算量低）
                if self.ppgACBaseline == nil {
                    // 采样率估个 50 Hz；如果你有真实值可替换
                    self.ppgACBaseline = RunningQuantile(q: 0.5, halflifeSec: self.ppgACWindowSec / 2.0, fps: 50)
                }
                let base = self.ppgACBaseline!.update(Double(au))
                let denom = max(abs(base), 1.0)
                let acPct = (Double(au) - base) / denom * 100.0

                self.ppgACBuf.append(ts: ts, v: Float(acPct))
            }
            .store(in: &bag)

        // PPI（逐拍事件 → 散点）
        pm.$lastPpiMs
            .sink { [weak self] msOpt in
                guard let self = self, let ms = msOpt else { return }

                let beatSec = Double(ms) / 1000.0

                if self.ppiLogicClock == nil {
                    // 第一次到样：以“当前系统时间”作为 T0
                    self.ppiLogicClock = CACurrentMediaTime()
                    self.ppiLastMs = ms
                    self.ppiBuf.append(ts: self.ppiLogicClock!, v: Float(ms))
                    return
                }

                // 正常累进：T_k = T_{k-1} + PPI_k
                self.ppiLogicClock! += beatSec

                // 容错：如果累进后的“逻辑时间”落后现在非常多（例如掉后台或长暂停），重置锚点
                let now = CACurrentMediaTime()
                if now - self.ppiLogicClock! > 5.0 { // 超过 5 秒落后就重置
                    self.ppiLogicClock = now
                }

                self.ppiLastMs = ms
                self.ppiBuf.append(ts: self.ppiLogicClock!, v: Float(ms))
            }
            .store(in: &bag)
    }

    // MARK: - 下采样：min–max binning，限制每条曲线点数
    private func downsample(_ t: [Double], _ v: [Float], maxPoints: Int) -> ([Double],[Float]) {
        guard t.count > maxPoints, maxPoints > 0 else { return (t, v) }
        let n = t.count
        let step = Double(n) / Double(maxPoints)
        var outT = [Double](); outT.reserveCapacity(maxPoints * 2)
        var outV = [Float]();  outV.reserveCapacity(maxPoints * 2)
        var i0 = 0.0
        for _ in 0..<maxPoints {
            let i1 = i0 + step
            let lo = Int(i0.rounded(.down))
            let hi = min(n - 1, Int(i1.rounded(.down)))
            var vmin = Float.greatestFiniteMagnitude
            var vmax = -vmin
            var tmin = t[lo], tmax = t[lo]
            for i in lo...hi {
                let x = v[i]
                if x < vmin { vmin = x; tmin = t[i] }
                if x > vmax { vmax = x; tmax = t[i] }
            }
            outT.append(tmin); outV.append(vmin)
            if vmax != vmin { outT.append(tmax); outV.append(vmax) }
            i0 = i1
        }
        return (outT, outV)
    }

    // MARK: - 对外快照接口（WaveView 每帧调用）
    func snapshotHR(now: Double)   -> ([Double],[Float]) { let s = hrBuf.snapshot(windowSec: config.winHR,  now: now);  return downsample(s.0, s.1, maxPoints: config.maxPointsPerTrack) }
    func snapshotECG(now: Double)  -> ([Double],[Float]) { let s = ecgBuf.snapshot(windowSec: config.winECG, now: now); return downsample(s.0, s.1, maxPoints: config.maxPointsPerTrack) }
    func snapshotPPG(now: Double)  -> ([Double],[Float]) { let s = ppgBuf.snapshot(windowSec: config.winPPG, now: now); return downsample(s.0, s.1, maxPoints: config.maxPointsPerTrack) }
    func snapshotPPG_AC(now: Double) -> ([Double],[Float]) {
        let s = ppgACBuf.snapshot(windowSec: config.winPPG, now: now)
        return downsample(s.0, s.1, maxPoints: config.maxPointsPerTrack)
    }
    func snapshotPPI(now: Double)  -> ([Double],[Float]) { let s = ppiBuf.snapshot(windowSec: config.winPPI, now: now); return s } // 散点无需下采样

    // MARK: - 重置（开始/停止采集时可选择调用）
    func clearAll() {
        // 简化处理：重新构造缓冲（避免遍历清空）
        // 若需要保留历史，可删去本方法
    }
}

// MARK: - 低成本“近似中值”估计器（用于 PPG 去趋势）
final class RunningQuantile {
    private let q: Double      // 分位数，0.5 即近似中值
    private let alpha: Double
    private var state: Double?

    ///
    /// - Parameters:
    ///   - q: 目标分位数（0.5 为中位）
    ///   - halflifeSec: 半衰期（秒），越小响应越快
    ///   - fps: 预期每秒样本数，用于推导平滑系数
    init(q: Double = 0.5, halflifeSec: Double = 0.75, fps: Double = 50) {
        self.q = q
        let tau = halflifeSec / log(2.0)
        self.alpha = 1.0 - exp(-1.0 / max(tau * max(fps, 1), 1e-6))
    }

    @discardableResult
    func update(_ x: Double) -> Double {
        guard let s = state else { state = x; return x }
        // 分位数目标的“朝向”更新：x>=s 往上取 (1-q)，x<s 往下取 q
        let step = alpha * (x >= s ? (1.0 - q) : -q)
        state = s + step * (x - s)
        return state!
    }

    var value: Double? { state }
}
