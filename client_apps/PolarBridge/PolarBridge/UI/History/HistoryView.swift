//
//  HistoryView.swift
//  PolarBridge
//
//  Created by lijian on 8/22/25.
//

import SwiftUI

struct HistoryView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("历史记录（占位）")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("这里将来展示录制历史 / 打开文件 / 分享等功能。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}
