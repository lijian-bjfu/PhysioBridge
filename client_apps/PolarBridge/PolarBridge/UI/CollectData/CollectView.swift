import SwiftUI

// 明确 Marker 数组的类型，降低 ForEach 推断难度
private struct MarkerSpec: Identifiable {
    let id = UUID()
    let label: MarkerLabel
    let icon: String
    let title: String
}
private let kMarkerSpecs: [MarkerSpec] = [
    .init(label: .baseline_start,     icon: "flag",            title: "基线开始"),
    .init(label: .stim_start,         icon: "play.fill",       title: "诱导开始"),
    .init(label: .stim_end,           icon: "stop.fill",       title: "诱导结束"),
    .init(label: .intervention_start, icon: "bolt.fill",       title: "干预开始"),
    .init(label: .intervention_end,   icon: "bolt.slash.fill", title: "干预结束")
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
    // 自定义事件输入面板
    @State private var showSetCustomEventSheet: Bool = false
    @State private var customEventNameInput: String = ""
    @State private var showSaveListSheet: Bool = false
    @State private var presetNameInput: String = ""
    @State private var presetDescInput: String = ""
    
    // 根据设置页面（settingsView）判断是否显示"采集进度"卡片
    @AppStorage("feature.progressLog.enabled") private var progressLogEnabled: Bool = FeatureFlags.progressLogEnabled
    
    // 根据设置页面（settingsView）判断是否显示"数据波形图"卡片
    @AppStorage("feature.wave.enabled") private var waveEnabled: Bool = FeatureFlags.waveEnabled
    
    // 需要以store初始化的ViewModel必须明确地使用主线程
    @StateObject private var progressVM: ProgressLogViewModel
    init() {
        // 在主线程里，显式注入同一个 store
        _progressVM = StateObject(
            wrappedValue: ProgressLogViewModel(store: AppStore.shared)
        )
    }
    // CollectView.swift 顶部
    @StateObject private var waveVM = WaveViewModel(pm: PolarManager.shared)

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
                                    // 先结束自定义事件的计时，再停止采集
                                    store.finishCurrentCustomMarker()
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
                                
                                // 按钮激活与停止条件
                                let isActive  = (store.markerActive == spec.label)
                                let isWaiting = store.isCollecting && (store.markerAllowedNext == spec.label) && !isActive

                                let uiState: MarkerUIState = {
                                    if isActive { return .active }
                                    if isWaiting { return .waiting }
                                    return .disabled
                                }()
                                
                                FixMarkerButtonPill(
                                    title: spec.title,
                                    systemIcon: spec.icon,
                                    uiState: uiState
                                ) {
                                    store.emitMarkerInOrder(spec.label)
                                }
                            }
                            // 第6个格子：添加事件（仅在采集中禁用；其余时刻始终可用）
                            Button {
                                showSetCustomEventSheet = true
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "plus.square.on.square")
                                    Text("添加事件").font(.caption2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)                          // 与固定标签区分的颜色
                            .disabled(store.isCollecting)           // 仅在采集中禁用
                            .opacity(store.isCollecting ? 0.35 : 1) // 视觉提示，但不受 canStart 等限制
                            .allowsHitTesting(!store.isCollecting)  // 避免外层禁用链路误伤
                        }
                        // 3.1 自定义事件序列（仅展示当前选中列表中的条目）
                        if let list = store.markerLists.selectedList {
                            let items = list.items
                            // 规则：只有“已连接设备 + 已选择数据 + 正在采集”时，才允许触发自定义事件
                            let canActivateCustom = hasDevice && hasSelection && isCollecting
                            let rowHeight: CGFloat = 60
                            let listHeight: CGFloat = min(CGFloat(items.count) * rowHeight, 320)

                            if !items.isEmpty {
                                List {
                                    ForEach(items.indices, id: \.self) { idx in
                                        let item = items[idx]
                                        let rowState = store.markerSeq.state(for: idx)
                                        let rowEnabled = canActivateCustom && store.markerSeq.canTrigger(index: idx)
                                        
                                        // 合成“用于渲染”的三态：只有满足可触发条件才显示 waiting，否则灰色
                                        let uiStateForRow = rowState.toUIState(enabled: rowEnabled)
                                        CustomMarkerRow(
                                            title: item.displayName,
                                            iconName: item.iconName ?? "tag",
                                            uiState: uiStateForRow,
                                            elapsed: {
                                                let now = Date().timeIntervalSince1970
                                                if let s = store.markerSeq.startedAt[idx], let e = store.markerSeq.endedAt[idx] {
                                                    return max(0, e - s)
                                                } else if rowState == .active, let s = store.markerSeq.startedAt[idx] {
                                                    return max(0, now - s)
                                                } else {
                                                    return 0
                                                }
                                            }(),
                                            onTap: {
                                                guard rowEnabled else { return }
                                                if store.markerSeq.canTrigger(index: idx) {
                                                    store.triggerCustomMarker(index: idx)
                                                }
                                            },
                                        )
                                        .listRowInsets(EdgeInsets())
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .deleteDisabled(store.markerSeq.state(for: idx) == .active)
                                        .frame(minHeight: rowHeight, alignment: .center)
                                        .contentShape(Rectangle())                       // 扩大命中区域
                                    }
                                    .onDelete { offsets in
                                        offsets.forEach { index in
                                            let id = items[index].id
                                            AppStore.shared.markerLists.removeItem(id, from: list.id)
                                        }
                                    }
                                }
                                .listStyle(.plain)
                                .padding(.top, 8)
                                // 为 List 提供明确的高度，避免 0 或矛盾约束
                                .frame(height: listHeight)
                                .scrollDisabled(false)   // 允许内部滚动，提升左滑识别

                                // 3.2 保存设置按钮（当列表存在至少一条）
                                Button {
                                    showSaveListSheet = true
                                } label: {
                                    Text("保存设置")
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .padding(.top, 8)
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
                // ───────── E. 数据波形 ─────────
                if showWaveCard {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("实时信号")
                                .font(.title3.weight(.bold))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            WaveView(model: waveVM)
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
        .sheet(isPresented: $showSetCustomEventSheet) {
            AddCustomMarkerView(
                defaultName: AppStore.shared.markerLists.selectedList.flatMap { list in
                    AppStore.shared.markerLists.nextDefaultLabel(in: list.id)
                } ?? "custom_event",
                onConfirm: { name in
                    // 通过被观察的 store 路径修改，确保刷新
                    let lists = store.markerLists
                    if let sel = lists.selectedList {
                        lists.appendItem(MarkerTemplate(displayName: name, baseColorHex: nil, iconName: "tag"), to: sel.id)
                        // 保持选中不变，显式触发视图刷新
                        // DispatchQueue.main.async { store.objectWillChange.send() }
                    } else {
                        let newList = lists.createList(name: "临时会话", desc: "本次采集的临时自定义事件")
                        lists.appendItem(MarkerTemplate(displayName: name, baseColorHex: nil, iconName: "tag"), to: newList.id)
                        lists.selectList(id: newList.id)
                        // DispatchQueue.main.async { store.objectWillChange.send() }
                    }
                },
                onCancel: { /* no-op */ }
            )
        }
        .sheet(isPresented: $showSaveListSheet) {
            SaveCustomMarkerView(
                onConfirm: { title, desc in
                    let lists = AppStore.shared.markerLists
                    // 取当前选中列表的条目，按新标题/描述保存为一份新的列表
                    let items = lists.selectedList?.items ?? []
                    let newList = lists.createList(name: title, desc: desc, items: items)
                    lists.selectList(id: newList.id)
                },
                onCancel: { /* no-op */ }
            )
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
        // 如果想“还得选了信号才显示”，用：
        // store.isCollecting && !store.selectedSignals.isEmpty
    }
    
    // 显示代码上传流的界面
    private var showWaveCard: Bool {
        // 是否显示信号信号流窗口的条件
        store.isCollecting && waveEnabled
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
