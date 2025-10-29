//
//  WrapPills.swift
//  PolarBridge
//
//  Created by lijian on 10/30/25.
//

import SwiftUI

/// 简单“自动换行”的 pill 容器（不依赖外部 FlowLayout，防止耦合）
struct WrapPills<Item: Hashable, Content: View>: View { // 泛型 + Hashable
    let items: [Item]
    let builder: (Item) -> Content

    init(items: [Item], @ViewBuilder builder: @escaping (Item) -> Content) {
        self.items = items
        self.builder = builder
    }

    var body: some View {
        // 自适应列宽（你原来的实现保留）
        let cols = [GridItem(.adaptive(minimum: 68), spacing: 8)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                builder(item)
            }
        }
    }
}
