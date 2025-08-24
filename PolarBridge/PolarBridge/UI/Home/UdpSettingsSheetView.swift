//
//  UdpSettingsSheetView.swift
//  PolarBridge
//
//  Created by lijian on 8/24/25.
//

import SwiftUI

fileprivate let udpPortFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .none
    f.minimum = 1
    f.maximum = 65535
    return f
}()

fileprivate enum UdpField { case host, port }

struct UdpSettingsSheetView: View {
    let initialHost: String
    let initialPort: Int
    let onCancel: () -> Void
    let onConfirm: (_ host: String, _ port: Int) -> Void

    @State private var host: String
    @State private var port: Int
    @FocusState private var focus: UdpField?

    init(initialHost: String, initialPort: Int,
         onCancel: @escaping () -> Void,
         onConfirm: @escaping (_ host: String, _ port: Int) -> Void) {
        self.initialHost = initialHost
        self.initialPort = initialPort
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _host = State(initialValue: initialHost)
        _port = State(initialValue: initialPort)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("UDP 目标") {
                    TextField("Host (IPv4 或 主机名)", text: $host)
                        .textContentType(.URL)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focus, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focus = .port }

                    TextField("Port", value: $port, formatter: udpPortFormatter)
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .port)
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
                            onConfirm(host.trimmingCharacters(in: .whitespacesAndNewlines),
                                      Int(port))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  !(1...65535).contains(port))
                    }
                }
            }
            .navigationTitle("设置 UDP")
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
            // 默认聚焦到 Host，便于快速编辑
            focus = .host
        }
    }
}
