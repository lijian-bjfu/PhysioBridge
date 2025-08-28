//
//  DebugView.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//

import SwiftUI

fileprivate let portFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .none
    f.minimum = 1
    f.maximum = 65535
    return f
}()

struct DebugView: View {
    @AppStorage("udpHost") private var udpHost: String = AppConfig.defaultUDPHost
    @AppStorage("udpPort") private var udpPort: Int = 9001

    @StateObject private var store = AppStore.shared
    
    private enum FocusField { case host, port }
    @FocusState private var focusField: FocusField?

    var body: some View {
        NavigationView {
            Form {
                Section("设备状态（手动切换）") {
//                    Picker("Verity", selection: Binding(
//                        get: { store.verityState },
//                        set: { store.setVerityState($0) }
//                    )) {
//                        ForEach(DeviceState.allCases) { st in
//                            Text(st.rawValue).tag(st)
//                        }
//                    }
//
//                    Picker("H10", selection: Binding(
//                        get: { store.h10State },
//                        set: { store.setH10State($0) }
//                    )) {
//                        ForEach(DeviceState.allCases) { st in
//                            Text(st.rawValue).tag(st)
//                        }
//                    }
                }
                // 目标配置
                Section("UDP 目标") {
                    TextField("Host (IPv4 或 主机名)", text: $udpHost)
                        .textContentType(.URL)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusField, equals: .host)
                        .submitLabel(.done)
                        .onSubmit { focusField = nil }   // 点键盘的“完成”可收起

                    TextField("Port", value: $udpPort, formatter: portFormatter)
                        .keyboardType(.numberPad)
                        .focused($focusField, equals: .port)
                        .submitLabel(.done)
                        .onSubmit { focusField = nil }

                    Button("应用设置") {
                        let p = UInt16(clamping: udpPort)
                        print("APPLY host=\(udpHost) port=\(p)")
                        store.applyTarget(host: udpHost, port: Int(p))
                        focusField = nil                 // 点“应用设置”也顺便收起键盘
                    }
                }

                // 连续发送控制
                Section("连续发送") {
                    if store.isCollecting {
                        Button("停止") {
                            print("STOP button tapped")
                            store.stopCollect()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button("开始每秒发送") {
                            print("START button tapped")
                            store.startCollect()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                // 发送一次
                Section("调试/单次发送") {
//                    Button("发送一次") {
//                        store.sendOnceHeartbeat()
//                    }
//                        .buttonStyle(.bordered)
                }

                // 状态
//                Section("状态") {
//                    HStack {
//                        Circle().fill(store.isCollecting ? .green : .gray)
//                            .frame(width: 10, height: 10)
//                        Text(store.isCollecting ? "正在连续发送" : "已停止")
//                    }
//                    Text("当前目标：\(udpHost):\(udpPort)")
//                    Text("累计发送：\(store.collectCount) 条")
//                    Text("最近一次：\(store.lastSentAt?.formatted(date: .omitted, time: .standard) ?? "—")")
//                        .foregroundStyle(.secondary)
//                }
//
//                // 实验标注
//                Section("实验标注") {
//                    Button("基线开始") { store.emitMarker(.baseline_start, )}
//                    Button("刺激开始") { store.emitMarker(.stim_start) }
//                    Button("刺激结束") { store.emitMarker(.stim_end) }
//                    Button("干预开始") { store.emitMarker(.intervention_start) }
//                    Button("干预结束") { store.emitMarker(.intervention_end)}
//                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusField = nil }   // 收起键盘
                }
            }
            .navigationTitle("调试工具")
        }
        .onAppear {
            _ = UdpMarkerBridge.shared // 建立对 MarkerBus 的订阅
        }
    }
}
