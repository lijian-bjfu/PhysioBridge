//
//  PolarBridgeApp.swift
//  PolarBridge
//
//  Created by lijian on 8/20/25.
//

import SwiftUI

@main
struct PolarBridgeApp: App {
    init() {
        // 1) 强制实例化单例，确保 init 执行并挂载观察者
        _ = PolarManager.shared

        // 2) 稍后切到主线程启动扫描（避免和 Scene 初始化时序竞争）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PolarManager.shared.startScan(prefix: "Polar")
        }

        // 3) 可选：在应用启动时输出一行标识
        print("[APP] did launch, scheduled scan start in 0.5s")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
