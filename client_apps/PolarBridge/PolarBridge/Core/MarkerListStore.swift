//
//  MarkerListStore.swift
//  PolarBridge
//
//  自定义 marker 列表的存取与选择。
//  持久化：UserDefaults；键名 pb.markerlists.v1 / pb.markerlists.v1.selected
//

import Foundation

@MainActor
final class MarkerListStore: ObservableObject {
    @Published private(set) var lists: [MarkerList] = []
    @Published var selectedListId: UUID?

    private let storageKey  = "pb.markerlists.v1"
    private let selectedKey = "pb.markerlists.v1.selected"

    init() {
        load()
        if selectedListId == nil { selectedListId = lists.first?.id }
    }

    var selectedList: MarkerList? {
        guard let id = selectedListId else { return nil }
        return lists.first(where: { $0.id == id })
    }

    // CRUD
    func createList(name: String, desc: String, items: [MarkerTemplate] = []) -> MarkerList {
        let list = MarkerList(name: name, desc: desc, items: items)
        lists.append(list)
        selectedListId = list.id
        save()
        return list
    }

    func updateList(_ list: MarkerList) {
        guard let idx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        lists[idx] = list
        save()
    }

    func deleteList(_ id: UUID) {
        lists.removeAll { $0.id == id }
        if selectedListId == id { selectedListId = lists.first?.id }
        save()
    }

    func reorderItems(in listId: UUID, fromOffsets: IndexSet, toOffset: Int) {
        guard let idx = lists.firstIndex(where: { $0.id == listId }) else { return }
        lists[idx].items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func appendItem(_ item: MarkerTemplate, to listId: UUID) {
        guard let idx = lists.firstIndex(where: { $0.id == listId }) else { return }
        lists[idx].items.append(item)
        save()
    }

    func removeItem(_ itemId: UUID, from listId: UUID) {
        guard let idx = lists.firstIndex(where: { $0.id == listId }) else { return }
        lists[idx].items.removeAll { $0.id == itemId }
        save()
    }

    func selectList(id: UUID?) {
        selectedListId = id
        saveSelected()
    }

    // 生成当前列表内唯一的默认 label：custom_event, custom_event1, custom_event2...
    func nextDefaultLabel(in listId: UUID, base: String = "custom_event") -> String {
        guard let list = lists.first(where: { $0.id == listId }) else { return base }
        var used = Set<Int>()
        for it in list.items {
            let name = it.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == base {
                used.insert(0)
                continue
            }
            if name.hasPrefix(base) {
                let tail = name.dropFirst(base.count)
                if let n = Int(tail) { used.insert(n) }
            }
        }
        var k = 0
        while used.contains(k) { k += 1 }
        return k == 0 ? base : "\(base)\(k)"
    }

    /// 追加一个带默认命名的条目到指定列表，并持久化
    @discardableResult
    func appendDefaultItem(to listId: UUID, baseName: String = "custom_event", iconName: String? = "tag") -> MarkerTemplate? {
        guard let idx = lists.firstIndex(where: { $0.id == listId }) else { return nil }
        let label = nextDefaultLabel(in: listId, base: baseName)
        let item = MarkerTemplate(displayName: label, baseColorHex: nil, iconName: iconName)
        lists[idx].items.append(item)
        save()
        return item
    }

    // 持久化
    func load() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: storageKey) {
            do {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .secondsSince1970
                self.lists = try dec.decode([MarkerList].self, from: data)
            } catch {
                print("[MarkerListStore] decode error: \(error)")
                self.lists = []
            }
        } else {
            // 无本地数据：保持为空，不注入示例
            self.lists = []
        }

        // 还原选中列表（若不存在则清空）
        if let sel = ud.string(forKey: selectedKey), let uuid = UUID(uuidString: sel) {
            if lists.contains(where: { $0.id == uuid }) {
                self.selectedListId = uuid
            } else {
                self.selectedListId = nil
            }
        } else {
            self.selectedListId = nil
        }
    }

    func save() {
        let ud = UserDefaults.standard
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(lists)
            ud.set(data, forKey: storageKey)
        } catch {
            print("[MarkerListStore] save error: \(error)")
        }
        saveSelected()
    }

    private func saveSelected() {
        let ud = UserDefaults.standard
        if let id = selectedListId {
            ud.set(id.uuidString, forKey: selectedKey)
        } else {
            ud.removeObject(forKey: selectedKey)
        }
    }

    // 可选：导入/导出
    func exportJSON() -> String? {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(lists)
            return String(data: data, encoding: .utf8)
        } catch {
            print("[MarkerListStore] export error: \(error)")
            return nil
        }
    }

    func importJSON(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        do {
            let dec = JSONDecoder()
            let newLists = try dec.decode([MarkerList].self, from: data)
            self.lists = newLists
            if selectedListId == nil { selectedListId = newLists.first?.id }
            save()
            return true
        } catch {
            print("[MarkerListStore] import error: \(error)")
            return false
        }
    }
}
