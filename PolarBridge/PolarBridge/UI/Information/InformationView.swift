import SwiftUI

/// InformationView
/// 目的：替换旧 DebugView，作为只读的“参考信息”页面。
struct InformationView: View {
    // 使用 @StateObject 确保 ViewModel 的生命周期与 View 绑定
    // 当 HomeView 创建并传入 ViewModel 时，View 会持有它
    @StateObject var viewModel: InformationViewModel
    
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
    
    /// 设备信息卡片
    private var deviceInfoCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("设备信息")
                    .font(.title3.weight(.bold))
                
                LabeledContent("设备名", value: viewModel.deviceName)
                LabeledContent("设备ID", value: viewModel.deviceID)
                
                LabeledContent("连接状态") {
                    Text(viewModel.connectionSummary.text)
                        .foregroundColor(viewModel.connectionSummary.color)
                        .fontWeight(.medium)
                }

                LabeledContent("电量", value: "—") // M2.3 中实现
                
                LabeledContent("支持数据") {
                    Text(viewModel.supportedFeatures.isEmpty ? "—" : viewModel.supportedFeatures.joined(separator: ", "))
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                
                LabeledContent("信号质量", value: "—") // M2.3 中实现
                
                Text("信号质量受距离与遮挡影响，差时更易中断与丢包。")
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
                
                // --- 修改代码 ---
                // 1. 绑定 isCollecting 状态，并根据状态显示不同文本
                LabeledContent("采集状态", value: viewModel.isCollecting ? "正在采集" : "未采集")
                
                // 2. 仅在采集开始后，才显示详细信息
                if viewModel.isCollecting {
                    Divider()
                    Text("当前订阅的信号")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // 动态流列表占位：后续用 ForEach(streamSummaries)
                    VStack(spacing: 8) {
                        ForEach(StreamPreviewItem.samples) { item in
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                GridRow {
                                    Text(item.name)
                                        .font(.body)
                                    Text(item.params)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                GridRow {
                                    Text("丢包(60s)")
                                        .foregroundStyle(.secondary)
                                    Text(item.loss)
                                        .font(.callout)
                                }
                            }
                            Divider()
                        }
                    }
                } else {
                    // 采集未开始时，显示提示语
                    Text("请您在采集页选择要测量的生理信号")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // --- 修改代码结束 ---
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    /// 会话信息卡片
    private var sessionInfoCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("会话信息")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                LabeledContent("Participant", value: "—")
                LabeledContent("Session", value: "—")
                LabeledContent("Phase", value: "—")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 预览与占位样本
private struct StreamPreviewItem: Identifiable {
    let id = UUID()
    let name: String
    let params: String
    let loss: String

    static let samples: [StreamPreviewItem] = [
        .init(name: "ECG", params: "130 Hz | 1 ch | uV", loss: "0.3%"),
        .init(name: "ACC", params: "100 Hz | 3 ch | ±4g", loss: "0.0%"),
        .init(name: "RR",  params: "事件流 | ms/beat",   loss: "—")
    ]
}

#Preview {
    NavigationStack {
        // 显式传入 AppStore.shared 来创建用于预览的 ViewModel
        InformationView(viewModel: InformationViewModel(store: AppStore.shared))
    }
}
