import SwiftUI

// MARK: - 历史页面（按“日”分组）
struct MarkerHistoryView: View {
    @ObservedObject private var store = AppStore.shared

    // 折叠状态（按日期分组的展开/收起）
    @State private var expandedDates: Set<DateKey> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groupedByDay.keys.sorted(by: >), id: \.self) { dayKey in
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            header(for: dayKey)

                            if expandedDates.contains(dayKey) {
                                let lists = groupedByDay[dayKey] ?? []
                                VStack(spacing: 12) {
                                    ForEach(lists, id: \.id) { list in
                                        MarkerHistoryCardView(list: list)
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            } else {
                                Text("（已折叠）")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if groupedByDay.isEmpty {
                    SectionCard {
                        VStack(spacing: 8) {
                            Text("暂无历史事件列表")
                                .font(.callout)
                            Text("在采集页添加并“保存设置”后，这里会显示历史记录。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .navigationTitle("事件历史")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 头：日期 + 展开/收起
    private func header(for key: DateKey) -> some View {
        HStack {
            Text(key.displayTitle)
                .font(.headline)
            Spacer()
            let expanded = expandedDates.contains(key)
            Button(expanded ? "收起" : "展开") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expanded { expandedDates.remove(key) } else { expandedDates.insert(key) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - 分组：把 lists 按“日”聚合
    private var groupedByDay: [DateKey: [MarkerList]] {
        var dict: [DateKey: [MarkerList]] = [:]
        for l in store.markerLists.lists {
            let k = DateKey(from: l.createdAt)
            dict[k, default: []].append(l)
        }
        // 每个组内，按 createdAt 倒序，新的在前
        for (k, arr) in dict {
            dict[k] = arr.sorted { $0.createdAt > $1.createdAt }
        }
        return dict
    }
}

// MARK: - 简单的“日”键（忽略时分秒）
private struct DateKey: Hashable, Comparable {
    let y: Int, m: Int, d: Int

    init(from date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        y = c.year ?? 1970
        m = c.month ?? 1
        d = c.day ?? 1
    }

    var displayTitle: String {
        "\(y)年\(m)月\(d)日"
    }

    static func < (lhs: DateKey, rhs: DateKey) -> Bool {
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.m != rhs.m { return lhs.m < rhs.m }
        return lhs.d < rhs.d
    }
}
