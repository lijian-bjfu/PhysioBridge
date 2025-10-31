//
//  MarkerHistoryCardView.swift
//  PolarBridge
//
//  Created by lijian on 10/31/25.
//

import SwiftUI

// MARK: - 单个历史列表卡片
struct MarkerHistoryCardView: View {
    @ObservedObject var store: AppStore = .shared
    let list: MarkerList

    // 折叠开关
    @State private var descExpanded: Bool = false
    @State private var eventsExpanded: Bool = false

    // 内部编辑态
    @State private var editingListName: String = ""
    @State private var editingListDesc: String = ""
    @State private var showAddItemSheet: Bool = false
    @State private var newItemName: String = ""

    // 删除整卡确认
    @State private var confirmDeleteList: Bool = false
    
    @FocusState private var focus: Field?
    enum Field { case name }

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                headerRow

                descBlock

                Divider()

                eventsBlock

                Divider().opacity(eventsExpanded ? 1 : 0)

                bottomActions
            }
            .onAppear {
                editingListName = list.name
                editingListDesc = list.desc
            }
        }
        // 新增事件输入弹窗
        .sheet(isPresented: $showAddItemSheet) {
            NavigationView {
                Form {
                    Section("新增事件") {
                        TextField("事件名称", text: $newItemName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section {
                        HStack {
                            Button("取 消") {
                                newItemName = ""
                                showAddItemSheet = false
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button("确 定") {
                                let name = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                store.markerLists.addItem(to: list.id, name: name)
                                newItemName = ""
                                showAddItemSheet = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .navigationTitle("添加事件")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .keyboard) {
                        HStack {
                            Spacer()
                            Button("完成") { focus = nil }
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("删除整个事件列表？", isPresented: $confirmDeleteList, titleVisibility: .visible) {
            Button("删除该列表", role: .destructive) {
                store.markerLists.deleteList(list.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可恢复。")
        }
    }

    // MARK: - 头部：标题 + 日期 + 改名保存
    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题可编辑
            TextField("列表标题", text: $editingListName, onCommit: {
                let name = editingListName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != list.name else { return }
                store.markerLists.renameList(id: list.id, name: name)
            })
            .font(.title3.bold())

            // 日期
            Text(list.createdAt.formatted(date: .long, time: .omitted))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 描述块：两行折叠，展开后可编辑
    private var descBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if descExpanded {
                TextEditor(text: $editingListDesc)
                    .frame(minHeight: 72)
                    .font(.body)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2))
                    )
                    .onChange(of: editingListDesc, initial: false) { _, newValue in
                        store.markerLists.updateDesc(id: list.id, desc: newValue)
                    }
            } else {
                Text(list.desc.isEmpty ? "（无描述）" : list.desc)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Button(descExpanded ? "收起描述" : "展开描述") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    descExpanded.toggle()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - 事件块：折叠/展开 + 重排 + 改名 + 删除
    private var eventsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("事件内容")
                    .font(.headline)
                Spacer()
                Button(eventsExpanded ? "收起事件" : "展开事件") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        eventsExpanded.toggle()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if eventsExpanded {
                EditableEventList(list: list)
            } else {
                Text("（已折叠）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 底部动作：新增事件 + 删除整卡
    private var bottomActions: some View {
        HStack {
            Button {
                newItemName = ""
                showAddItemSheet = true
            } label: {
                Label("添加事件", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            Button(role: .destructive) {
                confirmDeleteList = true
            } label: {
                Label("删除列表", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - 子视图：列表内事件的可编辑列表（拖拽、改名、删除）
private struct EditableEventList: View {
    @ObservedObject var store: AppStore = .shared
    let list: MarkerList

    @State private var localItems: [MarkerTemplate] = []

    var body: some View {
        // 使用 List 才能获得系统级拖拽排序与滑动删除的稳定手感
        List {
            ForEach(localItems) { item in
                EditableEventRow(
                    title: item.displayName,
                    iconName: item.iconName ?? "tag",
                    onRename: { newName in
                        store.markerLists.renameItem(in: list.id, itemId: item.id, to: newName)
                        reloadFromStore()
                    },
                    onDelete: {
                        store.markerLists.removeItem(item.id, from: list.id)
                        reloadFromStore()
                    }
                )
                .listRowSeparator(.hidden)
            }
            .onMove { from, to in
                store.markerLists.moveItems(in: list.id, fromOffsets: from, toOffset: to)
                reloadFromStore()
            }
            .onDelete { offsets in
                offsets.forEach { idx in
                    let item = localItems[idx]
                    store.markerLists.removeItem(item.id, from: list.id)
                }
                reloadFromStore()
            }
        }
        .listStyle(.plain)
        .frame(minHeight: min(CGFloat(max(localItems.count, 1)) * 56, 360))
        .environment(\.editMode, .constant(.active)) // 始终可拖拽
        .onAppear { reloadFromStore() }
        .onReceive(store.markerLists.$lists) { _ in reloadFromStore() }
    }

    private func reloadFromStore() {
        if let fresh = store.markerLists.lists.first(where: { $0.id == list.id })?.items {
            localItems = fresh
        }
    }
}

// MARK: - 单行：可改名 + 删除
private struct EditableEventRow: View {
    let title: String
    let iconName: String
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var name: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.primary)

            TextField("事件名", text: Binding(
                get: { name },
                set: { name = $0 }
            ), onCommit: {
                let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t != title else { return }
                onRename(t)
            })
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body)
        }
        .onAppear { name = title }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { onDelete() } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private extension MarkerHistoryCardView {
    static let longDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .none
        return df
    }()
}
