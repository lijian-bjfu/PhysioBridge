//
//  ProgressLogView.swift
//  PolarBridge
//
//  Created by lijian on 8/30/25.
//

import SwiftUI
import Combine

/// 采集进度日志（模拟版）
/// - 黑底绿字、等宽
/// - 固定 1s 节拍：ECG / PPG1 / RR / PPI 各打一行，然后一条方正型分隔线
/// - MARK 行贯穿屏幕，开始/结束用虚线框
/// - 仅用于 UI 验证；后续再接入真实数据源
struct ProgressLogView: View {
    // MARK: - State
    @State private var lines: [LogLine] = []
    @State private var tick: Int = 0
    @State private var timerCancellable: AnyCancellable?

    // 最近值（用于 1s 抽样；无新值则复用上次）
    @State private var lastECG: Int = -139
    @State private var lastPPG1: Int = 21345
    @State private var lastRR: Int = 823
    @State private var lastPPI: Int = 842

    private let maxLines = 200
    private let separator = "-  -  -  - "
    private let interval = 2

    var body: some View {
        // 黑底绿字的“电传纸带”容器
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundColor(line.color)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: lines.last?.id) { _, id in
                    guard let id = id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.25), lineWidth: 1)
        )
        .frame(minHeight: 220, maxHeight: 300)
        .onAppear(perform: startSimulation)
        .onDisappear { timerCancellable?.cancel() }
    }

    // MARK: - Simulation

    private func startSimulation() {
        lines.removeAll()
        tick = 0

        // 开始框
        append(separator)
        append(centered("开 始 采 集"), color: .green)
        append(separator)
        append("[\(ts(0))]  开始采集 (H10)")
        append("[\(ts(0))]  开始采集 (Verity)")
        append(separator, dim: true)

        // 1 秒节拍
        timerCancellable = Timer.publish(every: TimeInterval(interval), on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                tick += 1
                let elapsed = tick * interval     // 累计秒数
                let t = ts(elapsed)

                // 生成/复用最近值（模拟）
                lastECG += Int.random(in: -6...6)
                lastPPG1 += Int.random(in: -60...60)
                if Bool.random() { lastRR = max(600, min(1200, lastRR + Int.random(in: -40...40))) }
                if Bool.random() { lastPPI = max(600, min(1200, lastPPI + Int.random(in: -35...35))) }

                // 一秒内固定 4 行
                append("[\(t)]  ECG   \(lastECG) uV")
                append("[\(t)]  PPG1  \(lastPPG1) a.u.")
                append("[\(t)]  RR    \(lastRR) ms")
                append("[\(t)]  PPI   \(lastPPI) ms")

                // 示例 MARK：第 3 秒与第 8 秒
                if tick == 3 {
                    append("----- 基线_开始 -----", color: .cyan)
                }
                if tick == 8 {
                    append("----- 诱导_开始 -----", color: .cyan)
                }

                // 节拍分隔线（方正型）
                append(separator, dim: true)

                // 截断为环形缓冲
                trim()

                // 预览到第 18 秒结束
                if tick >= 18 {
                    append(separator)
                    append(centered("采 集 结 束"), color: .green)
                    append(separator)
                    timerCancellable?.cancel()
                }
            }
    }

    // MARK: - Helpers

    private func append(_ text: String, color: Color = .green, dim: Bool = false) {
        let c = dim ? color.opacity(0.35) : color
        lines.append(LogLine(text: text, color: c))
    }

    private func trim() {
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    private func centered(_ title: String) -> String {
        // 居中处理交给 UI；这里保持简单，直接输出标题行
        return " \(title) "
    }

    private func ts(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        // 固定毫秒 .000（UI 节拍 1s）
        return String(format: "%02d:%02d.000", m, s)
    }
}

// MARK: - Model

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}
