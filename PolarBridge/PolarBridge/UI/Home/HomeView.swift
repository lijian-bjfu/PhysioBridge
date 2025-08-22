import SwiftUI


struct HomeView: View {
    @StateObject private var store = AppStore.shared

    @AppStorage("udpHost") private var udpHost: String = AppConfig.defaultUDPHost
    @AppStorage("udpPort") private var udpPort: Int    = AppConfig.defaultUDPPort

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // 顶部提示横幅
//                    let hasDevice = store.verityConnected || store.h10Connected
//                    StatusBanner(
//                        title: "设备检测",
//                        message: hasDevice ? "已检测到可用设备。" : "尚未检测到可用设备…",
//                        tone: hasDevice ? .okay : .info
//                    )
//                    .padding(.horizontal)

                    // 设备区
                    Text("设备")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal)

                    let store = AppStore.shared
                    HStack(spacing: 16) {
                        DeviceCard(
                            title: "Polar Verity Sense",
                            state: store.verityState
                        ) {
                            store.tapDeviceCard("verity")
                        }

                        DeviceCard(
                            title: "Polar H10",
                            state: store.h10State
                        ) {
                            store.tapDeviceCard("h10")
                        }
                    }
                    .padding(.horizontal, 16) 

                    // 选择任务
                    SectionCard {
                        Text("选择任务")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        TaskRow(
                            title: "受试者信息",
                            subtitle: "记录被测基本信息",
                            enabled: true
                        ) {
                            // 先放一个占位页面
                            Text("受试者信息（占位）").padding()
                        }

                        Divider()

                        TaskRow(
                            title: "生理数据采集",
                            subtitle: "采集实验数据",
                            enabled: true
                        ) {
                            CollectView() // 你已有占位即可
                        }

                        Divider()

                        TaskRow(
                            title: "模拟数据测试",
                            subtitle: "基于模拟数据调试设备",
                            enabled: true
                        ) {
                            DebugView()
                        }
                    }
                    .padding(.horizontal)

                    // 最近数据（占位）
                    SectionCard {
                        Text("历史记录")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        TaskRow(
                            title: "记录历史",
                            subtitle: "查看历史记录信息",
                            enabled: true
                        ) {
                            HistoryView()   // ← 占位页面
                        }
                    }
                    .padding(.horizontal)

                    // 当前网络目标
                    Text("当前 UDP 目标：\(udpHost):\(udpPort)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("生理信号记录")
            .navigationBarTitleDisplayMode(.inline)
            
            // 扫描设备
            .onAppear {
                PolarManager.shared.startScan(prefix: "Polar")
            }
            .onDisappear {
                PolarManager.shared.stopScan()
            }
        }
    }
}



