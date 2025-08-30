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
    @ObservedObject var viewModel: ProgressLogViewModel   // ← 注入 VM

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.lines) { line in
                            Text(line.text)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundColor(line.color)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: viewModel.lines.last?.id) { _, id in
                    guard let id else { return }
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
    }
}
