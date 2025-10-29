//
//  Pill.swift
//  PolarBridge
//
//  Created by lijian on 10/30/25.
//

import SwiftUI

/// 轻量“药丸”标签
struct Pill: View {
    let text: String
    let selected: Bool
    let disabled: Bool
    var onTap: (() -> Void)? = nil          // ADDED

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.callout).fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
        .overlay(
            Capsule().stroke(selected ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 1)
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .opacity(disabled ? 0.5 : 1.0)
        .onTapGesture { if !disabled { onTap?() } }  // ADDED: 点击回调
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}
