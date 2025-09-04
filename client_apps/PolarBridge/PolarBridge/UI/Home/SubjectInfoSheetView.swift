//
//  SubjectInfoSheetView.swift
//  PolarBridge
//
//  Created by lijian on 8/24/25.
//

import SwiftUI

fileprivate enum SubjectField { case pid, sid }

struct SubjectInfoSheetView: View {
    let initialPID: String
    let initialSID: String
    let onCancel: () -> Void
    let onConfirm: (_ pid: String, _ sid: String) -> Void

    @State private var pid: String
    @State private var sid: String
    @FocusState private var focus: SubjectField?

    init(initialPID: String, initialSID: String,
         onCancel: @escaping () -> Void,
         onConfirm: @escaping (_ pid: String, _ sid: String) -> Void) {
        self.initialPID = initialPID
        self.initialSID = initialSID
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _pid = State(initialValue: initialPID)
        _sid = State(initialValue: initialSID)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("受试者信息") {
                    TextField("参与者编号（PID）", text: $pid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .pid)
                        .submitLabel(.next)
                        .onSubmit { focus = .sid }

                    TextField("测试编号（SESSIONID）", text: $sid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .sid)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                }

                Section {
                    HStack {
                        Button("取消") {
                            focus = nil
                            onCancel()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("确 定") {
                            focus = nil
                            let p = pid.trimmingCharacters(in: .whitespacesAndNewlines)
                            let s = sid.trimmingCharacters(in: .whitespacesAndNewlines)
                            onConfirm(p, s)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  sid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("受试者信息")
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
        .onAppear {
            focus = .pid
        }
    }
}
