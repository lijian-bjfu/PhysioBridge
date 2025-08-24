//
//  TaskRow.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//

import SwiftUI

import SwiftUI

struct TaskRow<Destination: View>: View {
    // 公共属性
    let title: String
    let subtitle: String
    var enabled: Bool = true

    // 两种模式的承载：A=action-only，B=destination sheet/nav
    private let action: (() -> Void)?
    private let destinationBuilder: (() -> Destination)?

    // B 模式（兼容旧用法）：提供 destination 闭包，点击即跳转/展示
    init(title: String,
         subtitle: String,
         enabled: Bool = true,
         @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.enabled = enabled
        self.destinationBuilder = destination
        self.action = nil
    }

    // A 模式（新增）：仅执行动作，不内置 sheet/目的页
    // 用法：TaskRow(title:..., subtitle:..., enabled: true, action: { ... })
    init(title: String,
         subtitle: String,
         enabled: Bool = true,
         action: @escaping () -> Void) where Destination == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.enabled = enabled
        self.action = action
        self.destinationBuilder = nil
    }

    var body: some View {
        Group {
            if let action = action {
                // A 模式：只执行回调，不展示内置 sheet
                NavigationLink(destination: EmptyView()) {
                    rowContent
                }
                .allowsHitTesting(false)  // 不响应点击，但仍然绘制与 NavigationLink 一致的行背景与右侧箭头
                .overlay {
                    // 透明的全行点击区域，触发 action
                    Rectangle()
                        .foregroundColor(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: action)
                }
            } else if let destinationBuilder = destinationBuilder {
                // B 模式：保留原逻辑（NavigationLink + destination）
                NavigationLink(destination: destinationBuilder()) {
                    rowContent
                }
            } else {
                // 正常不会到这里；兜底显示一行静态内容
                rowContent
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
    }

    // TaskRow.swift
    private var rowContent: some View {
        HStack(spacing: 12) {
            // 左侧图标占位（保持你原来的风格）
            Circle()
                .fill(enabled ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
    }
}


//struct TaskRow<Destination: View>: View {
//    let title: String
//    let subtitle: String
//    var enabled: Bool = true
//    @ViewBuilder var destination: () -> Destination
//
//    var body: some View {
//        NavigationLink(destination: destination()) {
//            HStack(spacing: 12) {
//                Circle()
//                    .fill(enabled ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
//                    .frame(width: 28, height: 28)
//
//                VStack(alignment: .leading, spacing: 4) {
//                    Text(title)
//                        .font(.headline)
//                        .lineLimit(1)
//                        .minimumScaleFactor(0.9)
//                    Text(subtitle)
//                        .font(.subheadline)
//                        .foregroundStyle(.secondary)
//                        .lineLimit(1)
//                        .minimumScaleFactor(0.9)
//                }
//                Spacer()
//                Image(systemName: "chevron.right")
//                    .foregroundStyle(.tertiary)
//            }
//            .contentShape(Rectangle())
//            .opacity(enabled ? 1.0 : 0.5)
//        }
//        .disabled(!enabled)
//    }
//}
