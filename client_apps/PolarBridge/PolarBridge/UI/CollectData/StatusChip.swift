//
//  StatusChip.swift
//  PolarBridge
//
//  Created by lijian on 10/30/25.
//

import SwiftUI

/// 横向小 Chip
// 等宽“标识”，无独立卡片样式（看起来就是大卡片里的行内元素）
// - 横向宽度固定，保证每个标识占位一致
// - 数值更大；单位紧跟数值；标题在下一行
struct StatusChip: View {
    let value: String
    let unit: String?
    let label: String
    var tint: Color = .primary

    // 统一等宽（你也可以换成基于屏宽的计算）
    private let chipWidth: CGFloat = 88

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold()).foregroundStyle(tint)
                if let unit = unit {
                    Text(unit).font(.subheadline.bold()).foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: chipWidth, alignment: .leading)   // 等宽占位（关键）
        // 无独立背景/边框：看起来就是“大卡片里的文字块”
    }
}
#Preview {
    StatusChip(value:"1", unit: "mb", label: "aaa" )
}
