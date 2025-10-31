//
//  SubjectInfoSheetView.swift
//  PolarBridge
//
//  Created by lijian on 8/24/25.
//

import SwiftUI

fileprivate enum SubjectField { case pid, tid }

struct SubjectInfoSheetView: View {
    let initialPID: String
    let initialTID: String
    let onCancel: () -> Void
    let onConfirm: (_ pid: String, _ tid: String) -> Void

    @State private var pid: String
    @State private var tid: String
    @FocusState private var focus: SubjectField?

    init(initialPID: String, initialTID: String,
         onCancel: @escaping () -> Void,
         onConfirm: @escaping (_ pid: String, _ tid: String) -> Void) {
        self.initialPID = initialPID
        self.initialTID = initialTID
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _pid = State(initialValue: initialPID)
        _tid = State(initialValue: initialTID)
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
                        .onSubmit { focus = .tid }

                    TextField("任务编号（TID）", text: $tid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .tid)
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
                            let s = tid.trimmingCharacters(in: .whitespacesAndNewlines)
                            onConfirm(p, s)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  tid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
