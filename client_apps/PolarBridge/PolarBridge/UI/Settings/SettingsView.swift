import SwiftUI

struct SettingsView: View {
    // 与系统持久化直接绑定
    // CollectView 显示信号流开关
    @AppStorage("feature.progressLog.enabled") private var progressLogEnabled: Bool = FeatureFlags.progressLogEnabled
    // CollectView 显示数据图形开关
    @AppStorage("feature.wave.enabled") private var waveEnabled: Bool = FeatureFlags.waveEnabled
    // 使用数据限制技术开关
    @AppStorage("feature.tx.cappedEnabled")   private var cappedTxEnabled: Bool   = FeatureFlags.cappedTxEnabled
    
    // 是否显示用于debug的打印信息
    @AppStorage("consoleVerbose") private var consoleVerbose: Bool = false
    
    @State private var tempMaxBytes: String = String(FeatureFlags.maxPacketBytes)

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // 采集显示
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("采集显示")
                                .font(.title3.weight(.bold))

                            LabeledContent("采集进度卡片") {
                                Toggle("", isOn: $progressLogEnabled)
                                    .labelsHidden()
                            }

                            Text("关闭后，采集中不显示“采集进度”的滚动信息流。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            
                            LabeledContent("采集数据波形") {
                                Toggle("", isOn: $waveEnabled)
                                    .labelsHidden()
                            }

                            Text("关闭后，采集中不显示实时“数据波形图”。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 传输策略
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("传输策略")
                                .font(.title3.weight(.bold))

                            LabeledContent("限制数据大小传输（≤阈值）") {
                                Toggle("", isOn: $cappedTxEnabled)
                                    .labelsHidden()
                            }

                            LabeledContent("单包上限") {
                                HStack(spacing: 8) {
                                    TextField("", text: $tempMaxBytes)
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(minWidth: 80)
                                    Text("Bytes").foregroundStyle(.secondary)
                                }
                            }

                            Text("建议 800–1400 Bytes。过小会增加包数，过大可能触发网络分片。默认 1200。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    SectionCard {
                       VStack(alignment: .leading, spacing: 12) {
                           Text("调试")
                               .font(.title3.weight(.bold))

                           LabeledContent("详细日志（总开关）") {
                               Toggle("", isOn: $consoleVerbose)
                                   .labelsHidden()
                           }
                           Text("关闭后仅保留关键日志（开始/停止/错误）。打开后会输出大量排查细节（队列、调用栈、批次等）。")
                               .font(.footnote)
                               .foregroundStyle(.secondary)
                       }
                       .frame(maxWidth: .infinity, alignment: .leading)
                   }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { applyAndDismiss() }
                        .bold()
                }
            }
        }
    }

    private func applyAndDismiss() {
        // 清洗输入
        let raw = tempMaxBytes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Int(raw) {
            FeatureFlags.maxPacketBytes = v   // 内部会夹取到 256...16384
        } else {
            FeatureFlags.maxPacketBytes = 1200
            tempMaxBytes = "1200"
        }
        // 同步两枚 Toggle 到 FeatureFlags（@AppStorage 已经写入了，这里只是确保全局静态也一致）
        FeatureFlags.progressLogEnabled = progressLogEnabled
        FeatureFlags.cappedTxEnabled    = cappedTxEnabled

        dismiss()
    }
}

