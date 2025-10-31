//
//  MarkerSequenceEngine.swift
//  PolarBridge
//
//  Created by lijian on 10/29/25.
//

//
//  MarkerSequenceEngine.swift
//  PolarBridge
//
//  自定义 marker 序列：数据结构 + 顺序执行状态机（仅发“单次 marker”）。
//  不触网；发送通过 MarkerBus.shared.emitCustom(name:) 完成。
//  不修改 AppStore / UDP / LSL；旧五键不受影响。
//  状态色由 UI 层决定，这里只给出运行态状态枚举。

/*
 这个引擎用于用户自建事件的添加、删除。下面是自建事件的典型流程：
 -----
 用例 A：用户“添加一条自定义事件”
 1.    点按钮
 CollectView 里“添加事件”按钮只受 isCollecting 限制，打开 SetCustomEventSheet。
 2.    弹窗点“确定”
 SetCustomEventSheet 把名字通过 onConfirm(name) 回传给 CollectView。
 3.    写入列表并持久化（即app内部保存的数据）
 CollectView 的回调里调用 MarkerListStore.appendItem(...)：
 store.markerLists.appendItem(tmpl, to: sel.id)   // 内部会 save()
 4.    序列引擎与 UI 同步
 重绑
 5.    界面可见
 CollectView 读取 selectedList.items 重建 List，新行出现。
 -----
 用例 B：用户“左滑删除一条事件”
 1.    UI 层拿到要删的索引
 List 的 .onDelete 给出 IndexSet，或你行内 onDelete 直接删某个 id。
 2.    删持久化（即app内部保存的数据）
 markerLists.removeItem(item.id, from: list.id)  // 内部 save()
 3.    序列引擎与 UI 同步
 删除后调用 store.markerSeq.rebind(list: selectedList, preserve: true)，保留已完成/当前索引不乱
 UI 列表因为数据源变了会重建，行位置与状态一致。
 -----
 用例 C：用户“点击某条事件，发出 marker”
 1.    UI 判定可触发
 当前规则是“遵守基础采集规则 + 序列下一条”：
 let canActivateCustom = /* 例如：只要求 isCollecting，或更严：hasDevice && hasSelection && isCollecting */
 let rowEnabled = canActivateCustom && store.markerSeq.canTrigger(index: idx)
 2.    触发序列引擎
 store.triggerCustomMarker(index: idx)   // AppStore → markerSeq.trigger(index:)
 3.    引擎推进与发包
 •    markerSeq.trigger 把上一条标记为结束、当前条记为开始；
 •    通过 MarkerBus.shared.emitCustom(name:) 发出自定义标记；
 •    UDPMarkerBridge 收到后封装 UDP；UDPSenderService 发送到目标 IP:port；
 •    电脑端 LSL 收到并写入事件流（label 即 displayName）。
 4.    UI 状态变化
 •    currentIndex 更新为 idx，行的 state(for:) 改为 .active；
 •    下一条行的 rowEnabled 会在“逐一执行”的规则下自动解锁。
 ----- ***** -----
 组件之间的通信拓扑（文字时序）
 •    CollectView
 → 增删事件 → MarkerListStore（持久化）
 → 触发事件 → AppStore.triggerCustomMarker(index:)
 → 读列表与状态 → markerLists.selectedList.items 与 markerSeq.state(...)
 •    AppStore
 → 启动时 markerSeq.bind(selectedList)
 → 监听 selectedListId 变化 → markerSeq.bind(...)
 → 监听 markerLists.$lists 变化 → markerSeq.rebind(..., preserve: true)
 → 封装 UI 门面：triggerCustomMarker 直接调 markerSeq.trigger
 •    MarkerSequenceEngine
 → 只产生活动状态与时间戳；
 → 调 MarkerBus.shared.emitCustom(name:) 发控制事件。
 •    MarkerBus / UDPMarkerBridge / UDPSenderService
 → 把控制事件送到电脑端 LSL，流程对 UI 透明。
 */

import Foundation
import Combine

// MARK: - 数据结构（可持久化）
struct MarkerTemplate: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String          // 作为 marker 的 label 原样发送
    var baseColorHex: String?        // 可选：仅 UI 主题装饰色（非状态色）
    var iconName: String?            // 可选：UI 图标名

    init(id: UUID = UUID(),
         displayName: String,
         baseColorHex: String? = nil,
         iconName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.baseColorHex = baseColorHex
        self.iconName = iconName
    }
}

struct MarkerList: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String                 // 列表名
    var desc: String                 // 列表用途描述
    var items: [MarkerTemplate]      // 顺序即执行顺序
    var version: Int = 1
    var createdAt: Date              // 新增：创建时间（用于“事件历史”分组）

    init(id: UUID = UUID(),
         name: String,
         desc: String,
         items: [MarkerTemplate],
         version: Int = 1,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.desc = desc
        self.items = items
        self.version = version
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, desc, items, version, createdAt
    }

    // 兼容旧版本：旧数据里没有 createdAt 时，默认用当前时间
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(UUID.self, forKey: .id)
        self.name      = try c.decode(String.self, forKey: .name)
        self.desc      = try c.decode(String.self, forKey: .desc)
        self.items     = try c.decode([MarkerTemplate].self, forKey: .items)
        self.version   = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,        forKey: .id)
        try c.encode(name,      forKey: .name)
        try c.encode(desc,      forKey: .desc)
        try c.encode(items,     forKey: .items)
        try c.encode(version,   forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

// MARK: - 运行态
enum MarkerRunState: Equatable {
    case waiting     // 等待执行（蓝）
    case active      // 当前激活（绿）
    case done        // 已完成（灰）
}

@MainActor
final class MarkerSequenceEngine: ObservableObject {

    // 当前绑定的列表，由上层在选择列表后注入
    @Published private(set) var list: MarkerList?

    // 运行指针：nil 表示尚未开始；否则指向“当前激活”的索引
    @Published private(set) var currentIndex: Int?

    // 计时：仅用于 UI 呈现，不会写入 marker
    @Published private(set) var startedAt: [Int: TimeInterval] = [:]
    @Published private(set) var endedAt:   [Int: TimeInterval] = [:]
    
    // 对外广播“本次触发的自定义事件名”
    private let _emitCustomMarker = PassthroughSubject<String, Never>()
    var emitCustomMarker: AnyPublisher<String, Never> { _emitCustomMarker.eraseToAnyPublisher() }

    // 轻量防抖，避免误触（秒）
    var minTapIntervalSec: Double = 0.12
    private var lastTapAt: TimeInterval = 0

    /// 用新列表重绑；preserve=true 时尽量保留 currentIndex / startedAt / endedAt
    func rebind(list newList: MarkerList?, preserve: Bool) {
        // 旧状态快照
        let oldCur = currentIndex
        let oldSta = startedAt
        let oldEnd = endedAt

        // 绑定新列表
        self.list = newList

        // 不保留进度或无新列表 → 全量复位
        guard preserve, let l = newList else {
            reset()
            return
        }

        // 仅当保留进度时，按新长度裁剪旧状态
        let n = l.items.count
        if n <= 0 {
            reset()
            return
        }

        // 裁剪开始/结束时间映射到新索引空间
        var newSta: [Int: TimeInterval] = [:]
        var newEnd: [Int: TimeInterval] = [:]
        for (k, v) in oldSta where k < n { newSta[k] = v }
        for (k, v) in oldEnd where k < n { newEnd[k] = v }
        startedAt = newSta
        endedAt   = newEnd

        // currentIndex 若越界则下调到尾部；否则保留
        if let oc = oldCur {
            currentIndex = oc < n ? oc : (n - 1)
        } else {
            currentIndex = nil
        }
    }

    // 绑定/复位（向后兼容）
    func bind(list newList: MarkerList?) {
        rebind(list: newList, preserve: false)
    }

    func reset() {
        currentIndex = nil
        startedAt.removeAll()
        endedAt.removeAll()
    }

    // 只允许触发“下一条”
    func canTrigger(index: Int) -> Bool {
        guard let l = list, l.items.indices.contains(index) else { return false }
        switch currentIndex {
        case nil:
            return index == 0
        case let .some(cur):
            // 不得回溯，不得跳跃
            return index == cur + 1
        }
    }

    // 触发：发送单个 marker；推进状态机；不发送“结束 marker”
    func trigger(index: Int) {
        guard canTrigger(index: index) else {
            print("[MarkerSeq] reject trigger index=\(index) current=\(currentIndex.map(String.init) ?? "nil")")
            return
        }
        guard allowTap() else { return }

        let now = Date().timeIntervalSince1970

        // 将上一条（如果有）标记为 done（仅运行态）
        if let cur = currentIndex {
            endedAt[cur] = now
        }

        // 发送本条 marker（仅一次）
        if let name = list?.items[index].displayName {
            MarkerBus.shared.emitCustom(name: name)
            _emitCustomMarker.send(name)
        }

        // 推进指针并记录开始时间
        currentIndex = index
        startedAt[index] = now
    }

    // 当前条完成（可选接口）：不发送 marker，只更新运行态
    func finishCurrent() {
        guard let cur = currentIndex else { return }
        let now = Date().timeIntervalSince1970
        endedAt[cur] = now
        currentIndex = cur + 1 < (list?.items.count ?? 0) ? cur + 1 : nil
    }

    // UI 查询：每个索引的状态
    func state(for index: Int) -> MarkerRunState {
        guard let l = list, l.items.indices.contains(index) else { return .waiting }
        if let cur = currentIndex {
            if index < cur { return .done }
            if index == cur { return .active }
            return .waiting
        } else {
            return index == 0 ? .waiting : .waiting
        }
    }

    // 内部：轻量防抖
    private func allowTap() -> Bool {
        let now = Date().timeIntervalSince1970
        if now - lastTapAt < minTapIntervalSec { return false }
        lastTapAt = now
        return true
        }
}
