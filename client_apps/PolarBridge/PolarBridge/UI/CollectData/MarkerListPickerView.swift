//
//  HistoryMarkerListPickerView.swift
//  PolarBridge
//
//  Created by lijian on 10/31/25.
//

import SwiftUI

/// 历史自定义事件列表选择页
struct MarkerListPickerView: View {
    /// 用户点选后回调选中的列表；回调里你可以 selectList / 克隆 / 其它处理
    let onPick: (MarkerList) -> Void

    // 直接读共享 Store
    @ObservedObject private var lists = AppStore.shared.markerLists
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if lists.lists.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暂无已保存的事件列表")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("可在采集页点击“保存设置”进行保存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(lists.lists) { list in
                        Button {
                            onPick(list)   // 交给外层决定如何处理
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(list.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if !list.desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(list.desc)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                    Text("事件数：\(list.items.count)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if lists.selectedListId == list.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("选择任一列表后，将替换当前自定义事件序列。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("导入历史列表")
        .navigationBarTitleDisplayMode(.inline)
    }
}
