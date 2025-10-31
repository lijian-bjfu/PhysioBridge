//
//  MarkerButtonPill.swift
//  PolarBridge
//
//  Created by lijian on 10/31/25.
//

import SwiftUI

struct FixMarkerButtonPill: View {
    let title: String
    let systemIcon: String
    let uiState: MarkerUIState          // active / waiting / disabled
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let token = MarkerUITheme.token(for: uiState, scheme: scheme)

        Button {
            if uiState != .disabled { action() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemIcon)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(token.fg)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(token.fg)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain) // 不用系统边框，保证与自定义事件一致
        .background(
            RoundedRectangle(cornerRadius: MarkerUITheme.cornerRadius).fill(token.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarkerUITheme.cornerRadius)
                .stroke(Color.clear, lineWidth: 0.001)
        )
        .allowsHitTesting(uiState != .disabled)
        .animation(.easeInOut(duration: 0.15), value: uiState)
    }
}
