//
//  EmptyHistoryCard.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//

import SwiftUI

struct EmptyHistoryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("暂无有记录")
                .font(.headline)
            Text("采集开始后，这里会显示最近一次录制的文件、时间、样本数，并提供一键打开/分享入口。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemBackground))
        )
    }
}
