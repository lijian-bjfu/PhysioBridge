/*
 自定义事件 view
 */
import SwiftUI

/// 自定义事件条目行：标题 + 图标 + 计时 + 点击/删除
struct CustomMarkerRow: View {
    let title: String
    let iconName: String?
    /// 运行态：waiting / active / done
    let uiState: MarkerUIState
    /// 用时
    let elapsed: TimeInterval
    var onTap: () -> Void
    
    // 使用系统白天晚上模式
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
 
        // 使用统一的事件ui颜色设置
        let token = MarkerUITheme.token(for: uiState, scheme: colorScheme)


        HStack(spacing: 8) {
            if let icon = iconName, !icon.isEmpty {
                Image(systemName: icon)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(token.fg)
            }
            Text(title)
                .font(.body)
                .foregroundStyle(token.fg)

            Spacer()

            Text(formatMMSS(elapsed))
                .font(.body.monospacedDigit())
                .foregroundStyle(token.fg)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(token.bg)
        )
        .overlay(
            // 无边框
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.clear, lineWidth: 0.0001)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if uiState == .waiting { onTap() }
        }
        .animation(.easeInOut(duration: 0.15), value: uiState)
    }

    func formatMMSS(_ t: TimeInterval) -> String {
        let x = max(0, Int(t))
        let m = x / 60, s = x % 60
        return String(format: "%02d:%02d", m, s)
    }
}


