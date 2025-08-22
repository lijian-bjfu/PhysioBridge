//
//  TaskRow.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//

import SwiftUI

struct TaskRow<Destination: View>: View {
    let title: String
    let subtitle: String
    var enabled: Bool = true
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 12) {
                Circle()
                    .fill(enabled ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1.0 : 0.5)
        }
        .disabled(!enabled)
    }
}
