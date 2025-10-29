//
//  WaveView.swift
//  PolarBridge
//
//  Created by lijian on 10/29/25.
//

import SwiftUI

struct WaveView: View {
    @ObservedObject var model: WaveViewModel

    // 统一样式
    private let trackHeight: CGFloat = 120
    private let axisInset: CGFloat = 8

    // 全局可调的窗口（秒）
    private let WIN_HR:  Double = 20
    private let WIN_PPI: Double = 15
    private let WIN_ECG: Double = 8
    private let WIN_PPG: Double = 10

    // 数据源类型，避免用标题字符串判断
    private enum TrackKind { case hr, ecg, ppgAC, ppi }

    var body: some View {
        VStack(spacing: 12) {
            // HR row
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("HR", isOn: $model.config.showHR)
                }
                if model.config.showHR {
                    track(title: "每秒心跳次数", kind: .hr, color: .primary)
                }
            }
            // ECG row
            if model.hasH10 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("ECG", isOn: $model.config.showECG)
                    }
                    if model.config.showECG {
                        track(title: "心电电压(μV)", kind: .ecg, color: .primary)
                    }
                }
            }
            // PPG row
            if model.hasVerity {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("PPG", isOn: $model.config.showPPG)
                    }
                    if model.config.showPPG {
                        track(title: "血量波动(%)", kind: .ppgAC, color: .primary)
                    }
                }
                // PPI row
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("PPI", isOn: $model.config.showPPI)
                    }
                    if model.config.showPPI {
                        scatter(title: "逐拍间期(毫秒)", kind: .ppi, color: .primary)
                    }
                }
            }
        }
        .onAppear {
            // 窗口宽度，低频数据窗口可大一些，高频数据窗口小一些
            model.config.winHR  = WIN_HR
            model.config.winPPI = WIN_PPI
            model.config.winECG = WIN_ECG
            model.config.winPPG = WIN_PPG
        }
    }

    // MARK: - 顶部开关（按设备可用性显示）
    @ViewBuilder
    private func headerToggles() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("HR", isOn: $model.config.showHR)
                if model.hasH10 {
                    Toggle("ECG", isOn: $model.config.showECG)
                }
            }
            HStack {
                if model.hasVerity {
                    Toggle("PPG", isOn: $model.config.showPPG)
                    Toggle("PPI", isOn: $model.config.showPPI)
                }
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: - 线型轨迹（HR/ECG/PPG）
    @ViewBuilder
    private func track(title: String, kind: TrackKind, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            TimelineView(.periodic(from: Date.now, by: 1.0/30.0)) { timeline in
                Canvas { ctx, size in
                    // Use CADisplayLink clock to match model timestamps (CACurrentMediaTime)
                    let now = CACurrentMediaTime()
                    _ = timeline.date    // keep dependency so TimelineView refreshes

                    let win: Double = {
                        switch kind {
                        case .hr:    return model.config.winHR
                        case .ecg:   return model.config.winECG
                        case .ppgAC: return model.config.winPPG
                        case .ppi:   return model.config.winPPI
                        }
                    }()
                    let xStart = now - win
                    let xEnd   = now

                    var t: [Double] = []
                    var v: [Float] = []
                    switch kind {
                    case .hr:    (t, v) = model.snapshotHR(now: now)
                    case .ecg:   (t, v) = model.snapshotECG(now: now)
                    case .ppgAC: (t, v) = model.snapshotPPG_AC(now: now)
                    case .ppi:   break
                    }

                    drawAxes(ctx: &ctx, size: size, t: t, v: v, title: title, kind: kind, xStart: xStart, xEnd: xEnd)
                    let p = path(for: t, v, in: size, xStart: xStart, xEnd: xEnd)
                    ctx.stroke(p, with: .color(.green), lineWidth: 1)
                }
            }
            .frame(height: trackHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
        }
    }

    // MARK: - 散点轨迹（PPI）
    @ViewBuilder
    private func scatter(title: String, kind: TrackKind, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            TimelineView(.periodic(from: Date.now, by: 1.0/30.0)) { timeline in
                Canvas { ctx, size in
                    // Use CADisplayLink clock to match model timestamps (CACurrentMediaTime)
                    let now = CACurrentMediaTime()
                    _ = timeline.date    // keep dependency so TimelineView refreshes
                    let win = model.config.winPPI
                    let xStart = now - win
                    let xEnd   = now

                    var t: [Double] = []
                    var v: [Float] = []
                    if case .ppi = kind { (t, v) = model.snapshotPPI(now: now) }

                    drawAxes(ctx: &ctx, size: size, t: t, v: v, title: title, kind: kind, xStart: xStart, xEnd: xEnd)
                    let pts = points(for: t, v, in: size, xStart: xStart, xEnd: xEnd)
                    let pointRadius: CGFloat = 3.0   // ← 调这里即可（例如 1.5 / 2.0 / 2.5 / 3.0）
                    for p in pts {
                        let r = CGRect(x: p.x - pointRadius, y: p.y - pointRadius,
                                       width: pointRadius * 2, height: pointRadius * 2)
                        ctx.fill(Path(ellipseIn: r), with: .color(.green))
                    }
                }
            }
            .frame(height: trackHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
        }
    }
    // MARK: - 坐标轴绘制
    private func drawAxes(ctx: inout GraphicsContext,
                          size: CGSize,
                          t: [Double], v: [Float],
                          title: String,
                          kind: TrackKind,
                          xStart: Double, xEnd: Double) {
        // Minimal axes: y axis at left, x axis at bottom, gridlines and ticks
        guard t.count > 1, v.count > 1 else { return }
        let axisColor = Color.gray.opacity(0.35)
        let minV = Double(v.min() ?? 0)
        let maxV = Double(v.max() ?? 1)
        let padRatio: Double = (kind == .ppgAC) ? 0.05 : 0.10  // PPG 5%，其余 10%
        let yPad = (maxV - minV) * padRatio
        let yMin = minV - yPad
        let yMax = maxV + yPad

        // 固定窗口映射到 [now - win, now]
        let t0 = xStart
        let t1 = xEnd
        
        let x0 = axisInset
        let x1 = size.width - axisInset
        let y0 = axisInset
        let y1 = size.height - axisInset
        // Y ticks —— 修改 targetCount 可改变刻度数
        let yTicks = tickValues(min: yMin, max: yMax, targetCount: 5)
        for yTick in yTicks {
            let y = y1 - CGFloat((yTick - yMin) / max(yMax - yMin, 1e-6)) * (y1 - y0)
            var path = Path()
            path.move(to: CGPoint(x: x0, y: y))
            path.addLine(to: CGPoint(x: x1, y: y))
            ctx.stroke(path, with: .color(axisColor), lineWidth: 0.5)
            let yLabel = Text(String(format: "%.0f", yTick))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.gray.opacity(0.7))
            // place the label centered on the tick line, slightly inset from the left axis
            ctx.draw(yLabel, at: CGPoint(x: x0 + 4, y: y), anchor: .leading)
        }
        // X ticks — fixed 1 s step across the current visible window [t0, t1]
        let step = 1.0
        let start = ceil(t0 / step) * step
        var xTicks: [Double] = []
        var tick = start
        while tick <= t1 + 1e-6 {
            xTicks.append(tick)
            tick += step
        }
        for xTick in xTicks {
            let x = x0 + CGFloat((xTick - t0) / max(t1 - t0, 1e-6)) * (x1 - x0)
            var path = Path()
            path.move(to: CGPoint(x: x, y: y0))
            path.addLine(to: CGPoint(x: x, y: y1))
            ctx.stroke(path, with: .color(axisColor), lineWidth: 0.5)
            let xLabel = Text(String(format: "%.0f", xTick - t0))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.gray.opacity(0.7))
            // place the label inside the bottom of the canvas (previously it was outside and got clipped)
            ctx.draw(xLabel, at: CGPoint(x: x - 8, y: y1 - 2), anchor: .bottomLeading)
        }
        // Y axis
        var yAxis = Path()
        yAxis.move(to: CGPoint(x: x0, y: y0))
        yAxis.addLine(to: CGPoint(x: x0, y: y1))
        ctx.stroke(yAxis, with: .color(axisColor), lineWidth: 1)
        // X axis
        var xAxis = Path()
        xAxis.move(to: CGPoint(x: x0, y: y1))
        xAxis.addLine(to: CGPoint(x: x1, y: y1))
        ctx.stroke(xAxis, with: .color(axisColor), lineWidth: 1)
    }

    // Helper for tick values
    private func tickValues(min: Double, max: Double, targetCount: Int) -> [Double] {
        guard max > min, targetCount > 0 else { return [] }
        let range = max - min
        let roughStep = range / Double(targetCount)
        // Find a nice step
        let mag = pow(10, floor(log10(roughStep)))
        let norm = roughStep / mag
        let step: Double
        if norm < 1.5 {
            step = 1 * mag
        } else if norm < 3 {
            step = 2 * mag
        } else if norm < 7 {
            step = 5 * mag
        } else {
            step = 10 * mag
        }
        let start = ceil(min / step) * step
        var ticks: [Double] = []
        var tick = start
        while tick <= max + 1e-6 {
            ticks.append(tick)
            tick += step
        }
        return ticks
    }

    // MARK: - 坐标换算：线型
    private func path(for t: [Double], _ v: [Float], in size: CGSize,
                      xStart: Double, xEnd: Double) -> Path {
        var path = Path()
        guard t.count > 0 else { return path }

        let minV = Double(v.min() ?? 0), maxV = Double(v.max() ?? 1)
        let dx = max(xEnd - xStart, 1e-6)
        let dv = max(maxV - minV, 1e-6)

        let wEff = size.width  - 2*axisInset
        let hEff = size.height - 2*axisInset

        for i in 0..<t.count {
            let x01 = ((t[i] - xStart) / dx).clamped(to: 0...1)
            let y01 = (Double(v[i]) - minV) / dv
            let x = axisInset + CGFloat(x01) * wEff
            let y = size.height - (axisInset + CGFloat(y01) * hEff)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    // MARK: - 坐标换算：散点
    private func points(for t: [Double], _ v: [Float], in size: CGSize,
                        xStart: Double, xEnd: Double) -> [CGPoint] {
        guard t.count > 0 else { return [] }

        let minV = Double(v.min() ?? 0), maxV = Double(v.max() ?? 1)
        let dx = max(xEnd - xStart, 1e-6)
        let dv = max(maxV - minV, 1e-6)

        let wEff = size.width  - 2*axisInset
        let hEff = size.height - 2*axisInset

        return (0..<t.count).map { i in
            let x01 = ((t[i] - xStart) / dx).clamped(to: 0...1)
            let y01 = (Double(v[i]) - minV) / dv
            let x = axisInset + CGFloat(x01) * wEff
            let y = size.height - (axisInset + CGFloat(y01) * hEff)
            return CGPoint(x: x, y: y)
        }
    }
}

// Clamp utility
extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
