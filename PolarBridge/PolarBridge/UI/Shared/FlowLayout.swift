//
//  FlowLayout.swift
//  PolarBridge
//
//  Created by lijian on 8/22/25.
//

import SwiftUI

// 放在 FlowLayout.swift 顶部或 FlexibleView 前面都行
private struct Indexed<Element>: Identifiable {
    let id: Int
    let value: Element
}


struct FlowLayout<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(alignment: HorizontalAlignment = .leading,
         spacing: CGFloat = 8,
         @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        // 先把 (offset, element) 元组 -> Indexed<AnyView>
        let _: [Indexed<AnyView>] =
            Array(ArrayMirror(of: content()).children.enumerated())
            .map { (idx, v) in Indexed(id: idx, value: v) }

        return FlexibleView(
            data: Array(ArrayMirror(of: content()).children),
            spacing: spacing,
            alignment: alignment
        ) { _, view in
            view
        }
    }
}

/// 一个简单的“自适应换行”容器：内部用 LazyVGrid 的 adaptive 列来模拟“流式排布”
/// - data: 任意可遍历的集合（比如 [AnyView]）
/// - content: 闭包签名固定为 `(索引, 元素)`，保持你原来的 `{ _, view in view }` 用法
struct FlexibleView<Data: RandomAccessCollection, Content: View>: View {
    let data: Data
    let spacing: CGFloat
    let alignment: HorizontalAlignment
    let content: (Int, Data.Element) -> Content

    init(
        data: Data,
        spacing: CGFloat = 16,
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder content: @escaping (Int, Data.Element) -> Content
    ) {
        self.data = data
        self.spacing = spacing
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        // 用自适应列宽来实现“自动换行”的视觉效果
        let columns = [
            GridItem(.flexible(), spacing: spacing, alignment: .leading)
        ]
        LazyVGrid(columns: columns, alignment: alignment, spacing: spacing) {
            // 注意这里我们自己做 enumerated，并用 \.0 当作 id
            ForEach(Array(data.enumerated()), id: \.0) { (idx, element) in
                content(idx, element)
            }
        }
    }
}

private struct WidthReader: View {
    var body: some View {
        GeometryReader { geo in Color.clear.preference(key: WidthKey.self, value: geo.size.width) }
    }
}
private struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 将任意 @ViewBuilder 内容枚举出来的小工具
private struct ArrayMirror: RandomAccessCollection {
    var startIndex: Int { views.startIndex }
    var endIndex: Int { views.endIndex }
    subscript(position: Int) -> AnyView { views[position] }

    let views: [AnyView]

    init<Content: View>(of content: Content) {
        // 简化：只处理 ForEach 产生的序列场景；占位足够用了
        self.views = Mirror(reflecting: content).children.compactMap { $0.value as? AnyView }
    }

    var children: [AnyView] { views }
}
