//
//  StatusBanner.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//

import SwiftUI

enum BannerTone { case info, okay, warn }

struct StatusBanner: View {
    let title: String
    let message: String
    var tone: BannerTone = .info

    private var bgColor: Color {
        switch tone {
        case .info: return Color.yellow.opacity(0.15)
        case .okay: return Color.green.opacity(0.15)
        case .warn: return Color.red.opacity(0.15)
        }
    }

    private var icon: String {
        switch tone {
        case .info: return "antenna.radiowaves.left.and.right"
        case .okay: return "checkmark.seal.fill"
        case .warn: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(bgColor)
        )
    }
}

