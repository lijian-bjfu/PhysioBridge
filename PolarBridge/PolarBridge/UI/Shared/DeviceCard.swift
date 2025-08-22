import SwiftUI

struct DeviceCard: View {
    let title: String
    let state: DeviceState       // 你的枚举：not_found / discovered / connecting / connected / failed / permission_missing
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemBackground))

                VStack(spacing: 2) {
                    Spacer(minLength: 6)
                    
                    // 顶部图标：留出上下/左侧空隙
                    Image(systemName: state.symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(state.tint)
                        .frame(maxWidth: .infinity) // 水平置中

                    Spacer(minLength: 4)
                    // 标题
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)

                    Spacer(minLength: 4)
                    
                    // 状态行：点 + 文案
                    HStack(spacing: 6) {
                        Circle().fill(state.tint).frame(width: 8, height: 8)
                        Text(state.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)       // ← 底部留白
                }
            }
            .frame(height: 150)                  // CHANGE: 卡片增高，原来更矮
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
