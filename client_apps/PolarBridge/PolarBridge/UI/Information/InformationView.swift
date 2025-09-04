import SwiftUI

fileprivate extension Int {
    var asBytesString: String { "\(self) B" }
}
fileprivate extension Double {
    var asBytesString: String { "\(Int(self.rounded())) B" }
}

struct InformationView: View {
    
    @AppStorage("feature.tx.maxPacketBytes") private var cappedEnabled: Bool = FeatureFlags.cappedTxEnabled
    
    @StateObject private var store = AppStore.shared
    // 当 HomeView 创建并传入 ViewModel 时，View 会持有它
    @ObservedObject private var viewModel: InformationViewModel
    
    // 显式初始化包装器，堵上 dynamicMember 的洞
    init(viewModel: InformationViewModel) {
        self._viewModel = ObservedObject(initialValue: viewModel)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 根据 ViewModel 的状态，在“空态”和“数据态”之间切换
                if !viewModel.hasDevice {
                    // MARK: 空态视图 (Empty State View)
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("设备信息")
                                .font(.title3.weight(.bold))
                            
                            // 绑定到新的 bluetoothStatus 元组，并应用颜色
                            LabeledContent("蓝牙状态") {
                                Text(viewModel.bluetoothStatus.text)
                                    .foregroundColor(viewModel.bluetoothStatus.color)
                                    .fontWeight(.medium) // 可选：加粗强调
                            }
                            
                            Text(viewModel.emptyPromptText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // MARK: 数据态视图 (Data State View)
                    deviceInfoCard
                    collectionInfoCard
                    sessionInfoCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .navigationTitle("参考信息")
        .navigationBarTitleDisplayMode(.inline)
        // 2. 在 View 上订阅 BluetoothManager 的状态发布
        .onReceive(BluetoothManager.shared.$bluetoothState) { newState in
            // 3. 将接收到的原始状态转换为布尔值
            let isOn = (newState == .poweredOn)
            // 4. 调用 ViewModel 的公共方法来更新状态
            viewModel.updateBluetoothState(isOn: isOn)
        }
    }

    // MARK: - 卡片视图构建
    
    // 设备信息卡片：关键是 ForEach 的这段
    private var deviceInfoCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("设备信息").font(.title3.weight(.bold))

                // 明确遍历“值” + 明确 id
                ForEach(viewModel.devices) { dev in
                    // 用一个容器兜住，避免 ViewBuilder 推断飘
                    VStack(alignment: .leading, spacing: 8) {
                        // 用闭包版本的 LabeledContent，传 Text，别用 value: 让它自己猜
                        LabeledContent("设备名") { Text(dev.name) }
                        LabeledContent("设备ID") { Text(dev.id) }
                        LabeledContent("连接状态") {
                            Text(dev.connection.text)
                                .foregroundColor(dev.connection.color)
                                .fontWeight(.medium)
                        }
                        LabeledContent("电量") { Text(dev.battery.map { "\($0)%" } ?? "—") }
                        LabeledContent("支持数据") {
                            Text(dev.supported.isEmpty ? "—" : dev.supported.joined(separator: ", "))
                                .font(.callout)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("信号强度") {
                            Text(dev.rssi.map { "\($0) dBm" } ?? "—")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 分隔线
                    if dev.id != viewModel.devices.last?.id {
                        Divider().padding(.vertical, 4)
                    }
                }

                Text("信号强度 0 - −55dBm为优，≈ −70dBm为一般，≤ −85dBm则较弱。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 采集信息卡片
    private var collectionInfoCard: some View {
        SectionCard{
            VStack(alignment: .leading, spacing: 12) {
                Text("采集信息")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                LabeledContent("采集状态") {
                    Text(viewModel.isCollecting ? "正在采集" : "未采集")
                        .foregroundColor(viewModel.isCollecting ? .green : .secondary)
                        .fontWeight(.medium)
                }

                if viewModel.isCollecting {
                    Divider()
                    Text("当前订阅的信号")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    let streams = viewModel.streamSummaries
                    
                    // 一个 Grid 包住所有条目，列宽统一
                    VStack (spacing: 8) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(streams.indices, id: \.self) { i in
                                let item = streams[i]
                                
                                // 行 1：名称 + 参数
                                GridRow {
                                    Text(item.name).font(.body)
                                    Text(item.params)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                
                                // 行 2：丢包(60s) 或者透明占位（保持行高一致）
                                if item.showsLossRow {
                                    GridRow {
                                        Text("丢包(60s)").foregroundStyle(.secondary)
                                        Text(item.lossRate?.formatted(.percent.precision(.fractionLength(1))) ?? "—")
                                            .font(.callout)
                                    }
                                } else {
                                    GridRow {
                                        Text("占位").font(.callout).opacity(0).gridCellColumns(2)
                                    }
                                }
                                
                                // 分隔线跨两列（不是放 Grid 外）
                                if i != streams.indices.last {
                                    GridRow { Divider().gridCellColumns(2) }
                                }
                            }
                        }
                    }
                    
                    
                    // 切包统计（仅当打开“限制数据大小传输”时显示）
                    if cappedEnabled {
                        let s = store.capStats
                        Divider()
                        Text("切包统计")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        LabeledContent("发生次数", value: s.count > 0 ? "\(s.count)" : "—")

                        LabeledContent("单包大小（字节）") {
                            if s.count == 0 || s.minBytes == .max {
                                Text("—").font(.callout)
                            } else {
                                Text("\(s.minBytes.asBytesString) / \(s.avgBytes.asBytesString) / \(s.maxBytes.asBytesString)")
                                    .font(.callout)
                            }
                        }
                    }
                    
                } else {
                    Text("请您在采集页选择要测量的生理信号")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    /// 参与者与实验编号信息卡片
    private var sessionInfoCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("实验编号")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                LabeledContent("Participant") { Text(viewModel.participantText) }
                LabeledContent("Session")     { Text(viewModel.sessionText) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    NavigationStack {
        // 显式传入 AppStore.shared 来创建用于预览的 ViewModel
        InformationView(viewModel: InformationViewModel(store: AppStore.shared))
    }
}
