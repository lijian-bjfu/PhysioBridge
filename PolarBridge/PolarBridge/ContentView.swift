import SwiftUI

struct ContentView: View {
    var body: some View {
        // 唯一入口：HomeView 放在一个 NavigationStack 里
        NavigationStack {
            HomeView()
        }
    }
}

#Preview {
    ContentView()
}

