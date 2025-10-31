//
//  MarkerUITheme.swift
//  PolarBridge
//
//  Created by lijian on 10/31/25.
//

import SwiftUI

/// UI 三态：与业务态解耦（业务态 waiting/active/done → 结合 enabled 转成 UI 三态）
enum MarkerUIState { case active, waiting, disabled }

/// 颜色令牌：背景/前景（如需描边、阴影可继续扩展）
struct MarkerToken {
    let bg: Color
    let fg: Color
}

/// 全局主题：集中管理配色与通用常量
struct MarkerUITheme {
    static let cornerRadius: CGFloat = 12

    // 浅/深色对“半透明填充”的感受不同，给两档更贴近系统按钮观感
    static func waitingBgOpacity(for scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.32 : 0.22
    }

    // 系统语义色：全部是动态色，跟随浅/深色与可访问性
    struct SystemPalette {
        static var waitingTint: Color { .accentColor }                         // 跟随系统/用户设置
        static var activeTint:  Color { Color(UIColor.systemGreen) }           // 系统绿（动态）
        // 禁用态底色改为系统灰阶，按浅/深色分档
        static func disabledFill(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(UIColor.systemGray4)   // 深色里稍深一点
                : Color(UIColor.systemGray5)   // 浅色里更接近实心禁用
        }
        static var disabledFG:   Color { Color(UIColor.tertiaryLabel) }        // 与系统禁用文字一致
        static var filledFG:     Color { .white }                              // 实心按钮白字
    }

    // 三态映射 → 颜色令牌
    static func token(for state: MarkerUIState, scheme: ColorScheme) -> MarkerToken {
        switch state {
        case .active:
            return .init(bg: SystemPalette.activeTint, fg: SystemPalette.filledFG)
        case .waiting:
            return .init(bg: SystemPalette.waitingTint.opacity(waitingBgOpacity(for: scheme)),
                         fg: SystemPalette.filledFG)
        case .disabled:
            return .init(bg: SystemPalette.disabledFill(scheme),
                         fg: SystemPalette.disabledFG)
        }
    }
}

/// 业务态到 UI 三态的映射辅助（业务 waiting + 可触发 → UI.waiting；active → UI.active；其余 disabled）
extension MarkerRunState {
    func toUIState(enabled: Bool) -> MarkerUIState {
        switch self {
        case .active: return .active
        case .waiting: return enabled ? .waiting : .disabled
        case .done: return .disabled
        }
    }
}
