//
//  SectionCard.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//

import SwiftUI

struct SectionCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
