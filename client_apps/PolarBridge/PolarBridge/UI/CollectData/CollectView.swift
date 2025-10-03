import SwiftUI

// 明确 Marker 数组的类型，降低 ForEach 推断难度
private struct MarkerSpec: Identifiable {
    let id = UUID()
    let label: MarkerLabel
    let icon: String
    let title: String
}
private let kMarkerSpecs: [MarkerSpec] = [
    .init(label: .baseline_start,     icon: "flag",           title: "基线开始"),
    .init(label: .stim_start,         icon: "play.fill",      title: "诱导开始"),
    .init(label: .stim_end,           icon: "stop.fill",      title: "诱导结束"),
    .init(label: .intervention_start, icon: "bolt.fill",      title: "干预开始"),
    .init(label: .intervention_end,   icon: "bolt.slash.fill",title: "干预结束"),
    .init(label: .custom_events,      icon: "tag",             title: "自定事件")
]


/// 采集页骨架：A 状态 → B 数据选择 → C 操作/计时/标记 → D 进度
struct CollectView: View {
    // 读 Store 的最小状态（T4-0 已添加）
    @ObservedObject private var store = AppStore.shared

    // 直接读 AppStorage，显示当前 UDP 目标（避免依赖 Store 内部实现细节）
    @AppStorage("udpHost") private var udpHost: String = AppConfig.defaultUDPHost
    @AppStorage("udpPort") private var udpPort: Int = AppConfig.defaultUDPPort
    
    // 用于驱动UI刷新，不参与实际计时
    @State private var displayTick: Int = 0
    @State private var uiTimer: Timer?
    
    // 根据设置页面（settingsView）判断是否显示"采集进度"卡片
    @AppStorage("feature.progressLog.enabled") private var progressLogEnabled: Bool = FeatureFlags.progressLogEnabled
    
    // 需要以store初始化的ViewModel必须明确地使用主线程
    @StateObject private var progressVM: ProgressLogViewModel
    init() {
        // 在主线程里，显式注入同一个 store
        _progressVM = StateObject(
            wrappedValue: ProgressLogViewModel(store: AppStore.shared)
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // ───────── A. 采集状态 ─────────
                SectionHeader("采集状态")
                Card {
                    // 统一把“空值”转成 0，并加单位
                    let trialText   = (store.trialID.isEmpty ? "0" : store.trialID)     // 例如 “2”
                    let subjectText = (store.subjectID ?? "0")                          // 例如 “10”
                    let statusText  = store.isCollecting ? "采集中" : "未开始"
                    let statusTint  : Color = store.isCollecting ? .green : .secondary
                    let markerText  = "\(max(0, store.markerCount))"                    // 例如 “2”

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            StatusChip(value: trialText,   unit: "次", label: "试次数")
                            StatusChip(value: subjectText, unit: "号", label: "被试 ID")
                            StatusChip(value: statusText,  unit: nil,  label: "采集状态", tint: statusTint)
                            StatusChip(value: markerText,  unit: "个", label: "标记数")

                            // 以后要扩展，继续往后 append 即可（等宽且可横滑）
                            // StatusChip(value: "...", unit: "...", label: "...")
                        }
                        .padding(.vertical, 6)
                    }
                }

                // ───────── B. 数据选择 ─────────
                SectionHeader("选择数据")
                Card {
                    // 可用信号集（由 AppStore 推导）
                    let available = availableSorted

                    if available.isEmpty {
                        // 无可订阅数据时的空态
                        VStack(spacing: 8) {
                            Text("未检测到可订阅数据")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("请先在首页连接 Verity / H10 等设备")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .padding(.vertical, 8)
                        .accessibilityLabel(Text("未检测到可订阅数据"))
                    } else {
                        // 有可订阅数据 → 生成可点击的 Pills
                        // 用 WrapPills 泛型
                        WrapPills(items: available) { kind in
                            let isSelected = store.selectedSignals.contains(kind)
                            // 点击切换选择
                            Pill(text: kind.title, selected: isSelected, disabled: false) {
                                store.toggleSelect(kind)
                            }
                            .padding(.vertical, 2)
                        }
                        .padding(.vertical, 4)
                        
                        Divider().padding(.top, 4)
                        
                        // 卡片下方增加只读“已选择”摘要
                        let details = store.selectedSignals
                            .map { kind -> String in
                                if let fs = kind.defaultFs, let rg = kind.defaultRangeG, kind == .vacc || kind == .hacc {
                                    return "\(kind.title)（\(kind.unit)@\(fs)Hz，±\(rg)G；\(kind.shortDesc)）"
                                } else if let fs = kind.defaultFs {
                                    return "\(kind.title)（\(kind.unit)@\(fs)Hz；\(kind.shortDesc)）"
                                } else {
                                    return "\(kind.title)（\(kind.unit)；\(kind.shortDesc)）"
                                }
                            }
                            .sorted()
                            .joined(separator: "、")

                        Text(details.isEmpty ? "未选择任何数据类型" : "已选择：\(details)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // ───────── C. 采集操作 / 计时 / 标记 ─────────
                SectionHeader("采集操作")
                Card {
                    // 可否开始：至少有设备已连接 + 选了至少一个信号
                    let hasDevice     = !store.availableSignals.isEmpty
                    let hasSelection  = !store.selectedSignals.isEmpty
                    let isCollecting  = store.isCollecting

                    // 仅当“有设备 + 选了至少一个信号”时可开始
                    let canStart      = hasDevice && hasSelection
                    // 未在采集中 → 按 canStart 控制；采集中 → 一直可“停止”
                    let disableStart  = isCollecting ? false : !canStart
                    let buttonTitle   = isCollecting ? "停止采集" : "开始采集"

                    // 计时文案（总计时）
                    let _ = displayTick                 // 触发 0.25s 刷新
                    let elapsed = store.elapsedSeconds()
                    let elapsedText = store.formatMMSS(elapsed)

                    VStack(spacing: 12) {
                        // 1) 大按钮：固定高度，只显示总计时
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isCollecting {
                                    store.stopCollect()     // 这里会把 isCollecting 置为 false
                                } else {
                                    store.startCollect()    // 这里会把 isCollecting 置为 true
                                }
                            }
                        } label: {
                            VStack {
                                Text(buttonTitle).font(.title3).bold()
                                Text("持续时间  \(elapsedText)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 68)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isCollecting ? .red : .accentColor)
                        .disabled(disableStart)

                        // 2) 阶段计时条（固定区域，不抖动）
                        // 先用 00:00 占位；等 AppStore 加上阶段累计后把下面三行替换为真实值
                        let _ = displayTick
                        let now = Date()
                        let baselineText = store.formatMMSS(store.elapsedBaseline(now))
                        let stimText     = store.formatMMSS(store.elapsedStim(now))
                        let intervText   = store.formatMMSS(store.elapsedIntervention(now))
                        
                        let baselineStarted = store.markerStep >= 0   // baseline_start 已触发
                        let stimStarted     = store.markerStep >= 1   // stim_start 已触发
                        let intervStarted   = store.markerStep >= 3   // intervention_start 已触发

                        // 当前激活高亮（由最后一次“开始”型标记决定）
                        let activeBaseline = (store.markerActive == .baseline_start)
                        let activeStim     = (store.markerActive == .stim_start)
                        let activeInterv   = (store.markerActive == .intervention_start)

                        HStack(spacing: 8) {
                            StageChip(title: "基线", timeText: baselineText, started: baselineStarted, active: activeBaseline)
                            StageChip(title: "诱导", timeText: stimText,     started: stimStarted,     active: activeStim)
                            StageChip(title: "干预", timeText: intervText,   started: intervStarted,   active: activeInterv)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)  // 固定高度，保证布局稳定

                        // 3) 标记按钮条：五等分网格，与上方对齐
                        let markerColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
                        LazyVGrid(columns: markerColumns, alignment: .center, spacing: 8) {
                            ForEach(kMarkerSpecs) { spec in
                                let isCustom = (spec.label == .custom_events)
                                let enabled  = isCollecting && (isCustom || store.markerAllowedNext == spec.label)
                                let isActive = (store.markerActive == spec.label)

                                // 统一按钮内容
                                let labelView = VStack(spacing: 4) {
                                    Image(systemName: spec.icon)
                                    Text(spec.title).font(.caption2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)

                                if isActive {
                                    Button { store.emitMarkerInOrder(spec.label) } label: { labelView }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.blue)
                                        .disabled(!enabled)
                                } else {
                                    Button { store.emitMarkerInOrder(spec.label) } label: { labelView }
                                        .buttonStyle(.bordered)
                                        .tint(.accentColor)
                                        .disabled(!enabled)
                                }
                            }
                        }
                    }
                }
                // ───────── D. 采集进度 ─────────
                if showProgressCard {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("采集进度")
                                .font(.title3.weight(.bold))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            ProgressLogView(viewModel: progressVM)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .navigationTitle("生理数据采集")
        .onAppear {
            // ↑ 仅用于刷新UI
            uiTimer?.invalidate()
            uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                displayTick &+= 1
            }
            RunLoop.main.add(uiTimer!, forMode: .common)
        }
        .onDisappear {
            uiTimer?.invalidate()
            uiTimer = nil
        }
    }
}

private extension CollectView {
    // 把“可用信号排序”拆出来，避免在视图树里做复杂闭包
    var availableSorted: [SignalKind] {
        Array(store.availableSignals).sorted { $0.rawValue < $1.rawValue }
    }
    
    // 显示代码上传流的界面
    private var showProgressCard: Bool {
        // 是否显示信号信号流窗口的条件
        store.isCollecting && progressLogEnabled
        // 如果你想“还得选了信号才显示”，用：
        // store.isCollecting && !store.selectedSignals.isEmpty
    }
}
// MARK: - 下面是本文件内的轻量 UI 工具

/// 小节标题
private struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 通用卡片容器
private struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

/// 轻量“药丸”标签
private struct Pill: View {
    let text: String
    let selected: Bool
    let disabled: Bool
    var onTap: (() -> Void)? = nil          // ADDED

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.callout).fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
        .overlay(
            Capsule().stroke(selected ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 1)
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .opacity(disabled ? 0.5 : 1.0)
        .onTapGesture { if !disabled { onTap?() } }  // ADDED: 点击回调
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

/// 简单“自动换行”的 pill 容器（不依赖外部 FlowLayout，防止耦合）
private struct WrapPills<Item: Hashable, Content: View>: View { // 泛型 + Hashable
    let items: [Item]
    let builder: (Item) -> Content

    init(items: [Item], @ViewBuilder builder: @escaping (Item) -> Content) {
        self.items = items
        self.builder = builder
    }

    var body: some View {
        // 自适应列宽（你原来的实现保留）
        let cols = [GridItem(.adaptive(minimum: 68), spacing: 8)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                builder(item)
            }
        }
    }
}

/// 横向小 Chip
// 等宽“标识”，无独立卡片样式（看起来就是大卡片里的行内元素）
// - 横向宽度固定，保证每个标识占位一致
// - 数值更大；单位紧跟数值；标题在下一行
private struct StatusChip: View {
    let value: String
    let unit: String?
    let label: String
    var tint: Color = .primary

    // 统一等宽（你也可以换成基于屏宽的计算）
    private let chipWidth: CGFloat = 88

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold()).foregroundStyle(tint)
                if let unit = unit {
                    Text(unit).font(.subheadline.bold()).foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: chipWidth, alignment: .leading)   // 等宽占位（关键）
        // 无独立背景/边框：看起来就是“大卡片里的文字块”
    }
}
/// 阶段计时小卡：上方时间（mm:ss），下方标签；
/// - active：当前阶段正在运行 → 高亮底色/描边
/// - started：这个阶段是否已经开始过 → 决定时间文字是灰色还是黑色
private struct StageChip: View {
    let title: String
    let timeText: String
    let started: Bool
    let active: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(timeText)
                    .font(.title3.bold())
                    .monospacedDigit()
                    .foregroundStyle(started ? .primary : .secondary)   // 未开始→灰色，开始→黑色
                Text("") // 保留给将来加单位；现在留空保持版式一致
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity) // 三等分
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(active ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(active ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: active)
    }
}


/// 简单 key-value 行
private struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

