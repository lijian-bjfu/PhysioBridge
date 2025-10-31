import SwiftUI

/// “添加自定义事件”弹窗（导航栈 + 表单）
struct AddCustomMarkerView: View {
    let defaultName: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    enum Field { case name }

    init(defaultName: String,
         onConfirm: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.defaultName = defaultName
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = State(initialValue: defaultName)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Section 1: 新建单条事件
                Section("新增自定义事件") {
                    TextField("事件标签（如：标注_1）", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .name)
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
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            focus = nil
                            onConfirm(trimmed)   // 交给外部把该事件 append 到当前列表
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // Section 2: 导入历史列表
                Section {
                    NavigationLink {
                        MarkerListPickerView(
                            onPick: { list in
                                // 1) 直接切换选中列表（会触发 rebind，UI 自动刷新）
                                AppStore.shared.markerLists.selectList(id: list.id)
                                // 2) 关闭两层：先退回上一层，再整体 dismiss
                                // 由于在同一 NavigationStack 内，这里只需 dismiss 一次即可交给外层
                                dismiss()
                            }
                        )
                    } label: {
                        HStack {
                            Image(systemName: "tray.and.arrow.down.fill")
                            Text("导入历史事件标注")
                        }
                    }
                } footer: {
                    Text("载入新的历史事件列表会清除当前自定义事件。")
                }
            }
            .navigationTitle("添加自定义事件")
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
        .onAppear { focus = .name }
    }
}
