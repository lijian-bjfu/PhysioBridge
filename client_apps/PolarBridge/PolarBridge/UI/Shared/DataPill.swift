//
//  DataPill.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//  做可选数据小卡片

import SwiftUI

// DataPill 增强为可选中/取消的可点击胶囊
struct DataPill: View {
    let kind: SignalKind
    let selected: Bool
    var action: (() -> Void)? = nil

    var body: some View {
        // 统一样式：图标 + 文本，选中时实心，未选中时描边
        HStack(spacing: 6) {
            Image(systemName: kind.sfSymbol)
                .imageScale(.small)
            Text(kind.title)
                .font(.callout)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12)) // CHANGED
        .overlay(
            Capsule()
                .stroke(selected ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 1)
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture { action?() }      // ADDED
        .animation(.easeInOut(duration: 0.15), value: selected)
        .accessibilityLabel(Text("\(kind.title)\(selected ? " 已选中" : " 未选中")"))
    }
}

