import SwiftUI

/// 将当前自定义事件序列保存为“预设列表”的弹窗
struct SavePresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var desc: String  = ""

    let onConfirm: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("保存为预设")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("预设名称（必填）", text: $title)
                .textFieldStyle(.roundedBorder)

            TextField("预设描述（可选）", text: $desc, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            HStack {
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("保存") {
                    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    onConfirm(t, desc)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
