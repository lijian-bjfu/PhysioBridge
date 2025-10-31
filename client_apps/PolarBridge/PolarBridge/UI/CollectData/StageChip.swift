//
//  StageChip.swift
//  PolarBridge
//
//  Created by lijian on 10/30/25.
//

import SwiftUI

/// 阶段计时小卡：上方时间（mm:ss），下方标签；
/// - active：当前阶段正在运行 → 高亮底色/描边
/// - started：这个阶段是否已经开始过 → 决定时间文字是灰色还是黑色
struct StageChip: View {
    let title: String
    let timeText: String
    let started: Bool
    let active: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(timeText)
                    .font(.title3.bold())
                    .monospacedDigit()
                    .foregroundStyle(started ? .primary : .secondary)   // 未开始→灰色，开始→黑色
                Text("") // 保留给将来加单位；现在留空保持版式一致
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity) // 三等分
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(active ? .green.opacity(0.12) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(active ? .green : Color.gray.opacity(0.35), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: active)
    }
}
