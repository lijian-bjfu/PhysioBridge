//
//  Config.swift
//  PolarBridge
//
//  Created by lijian on 8/21/25.
//

// UI/Shared/Config.swift

// UI/Shared/Config.swift
import Foundation

enum AppConfig {
    static let defaultUDPHost: String = {
        #if targetEnvironment(simulator)
        return "127.0.0.1"
        #else
        return "192.168.1.104"   // ← 你的 Mac 局域网 IP
        #endif
    }()
    
    /// 统一默认 UDP 端口（和 udp_to_lsl.py 保持一致）
    static let defaultUDPPort: Int = 9001
}
