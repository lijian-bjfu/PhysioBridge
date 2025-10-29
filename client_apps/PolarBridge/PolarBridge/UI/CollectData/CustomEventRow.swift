import SwiftUI

/// 自定义事件条目行：标题 + 图标 + 计时 + 点击/删除
struct CustomEventRow: View {
    let title: String
    let iconName: String?
    let state: MarkerRunState
    let elapsed: TimeInterval
    var onTap: () -> Void
    var onDelete: () -> Void

    var body: some View {
        let isActive = (state == .active)
        let isDone   = (state == .done)

        HStack(spacing: 8) {
            if let icon = iconName, !icon.isEmpty {
                Image(systemName: icon)
                    .foregroundStyle(isDone ? .secondary : .primary)
            }
            Text(title)
                .font(.body)
                .foregroundStyle(isDone ? .secondary : .primary)

            Spacer()

            Text(formatMMSS(elapsed))
                .font(.body.monospacedDigit())
                .foregroundStyle(isActive ? .green : .secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.accentColor.opacity(0.12)
                               : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.accentColor
                                 : Color.gray.opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        // iOS 15+ 原生左滑删除；更低版本退回到长按菜单
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    func formatMMSS(_ t: TimeInterval) -> String {
        let x = max(0, Int(t))
        let m = x / 60, s = x % 60
        return String(format: "%02d:%02d", m, s)
    }
}
