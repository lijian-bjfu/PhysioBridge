import SwiftUI

/// 将当前自定义事件序列保存为“预设列表”的弹窗（与 SubjectInfoSheetView 保持布局风格一致）
fileprivate enum PresetField { case title, desc }

struct SaveCustomMarkerView: View {
    @Environment(\.dismiss) private var dismiss

    // 输入状态
    @State private var title: String = ""
    @State private var desc: String  = ""
    @FocusState private var focus: PresetField?

    // 回调
    let onConfirm: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("预设信息") {
                    TextField("预设名称（必填）", text: $title)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focus = .desc }

                    TextField("预设描述（可选）", text: $desc, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .desc)
                        .lineLimit(3...6)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                }

                Section {
                    HStack {
                        Button("取消") {
                            focus = nil
                            onCancel()
                            dismiss()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("确 定") {
                            focus = nil
                            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            let d = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            onConfirm(t, d)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("保存为预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("完成") { focus = nil }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { focus = .title }
        .onDisappear { focus = nil }
        .padding(.top, 1) // 细微顶边距，使视觉与其他表单一致
    }
}
