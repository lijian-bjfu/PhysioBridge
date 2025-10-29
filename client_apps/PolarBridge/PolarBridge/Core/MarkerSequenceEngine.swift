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

    init(id: UUID = UUID(),
         name: String,
         desc: String,
         items: [MarkerTemplate],
         version: Int = 1) {
        self.id = id
        self.name = name
        self.desc = desc
        self.items = items
        self.version = version
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

    // 轻量防抖，避免误触（秒）
    var minTapIntervalSec: Double = 0.12
    private var lastTapAt: TimeInterval = 0

    // 绑定/复位
    func bind(list: MarkerList?) {
        self.list = list
        reset()
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
