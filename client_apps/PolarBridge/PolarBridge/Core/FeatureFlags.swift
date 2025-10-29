//
//  FeatureFlags.swift.swift
//  PolarBridge
//
//  Created by lijian on 8/30/25.
//

import Foundation

enum FeatureFlags {
    // UserDefaults keys
    private static let kProgressEnabled = "feature.progressLog.enabled"
    private static let kWaveEnabled = "feature.wave.enabled"
    private static let kCappedEnabled   = "feature.tx.cappedEnabled"
    private static let kMaxPacketBytes  = "feature.tx.maxPacketBytes"

    // 推荐范围（用来夹取，防止用户作死）
    private static let minBytes = 256
    private static let maxBytes = 16_384
    private static let defaultBytes = 1200
    
    // 详细日志开关（总开关）
    private static let kConsoleVerbose = "consoleVerbose"

    /// 总开关：是否打印大量调试详情（默认 false）
    public static var consoleVerbose: Bool {
        get { UserDefaults.standard.bool(forKey: kConsoleVerbose) }
        set { UserDefaults.standard.set(newValue, forKey: kConsoleVerbose) }
    }

    // MARK: - Flags

    static var progressLogEnabled: Bool {
        get {
            let ud = UserDefaults.standard
            if ud.object(forKey: kProgressEnabled) == nil { ud.set(true, forKey: kProgressEnabled) }
            return ud.bool(forKey: kProgressEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kProgressEnabled)
            notifyChange()
        }
    }
    
    static var waveEnabled: Bool {
        get {
            let ud = UserDefaults.standard
            if ud.object(forKey: kWaveEnabled) == nil { ud.set(true, forKey: kWaveEnabled) }
            return ud.bool(forKey: kWaveEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kWaveEnabled)
            notifyChange()
        }
    }

    static var cappedTxEnabled: Bool {
        get {
            let ud = UserDefaults.standard
            if ud.object(forKey: kCappedEnabled) == nil { ud.set(false, forKey: kCappedEnabled) }
            return ud.bool(forKey: kCappedEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kCappedEnabled)
            notifyChange()
        }
    }

    static var maxPacketBytes: Int {
        get {
            let ud = UserDefaults.standard
            if ud.object(forKey: kMaxPacketBytes) == nil { ud.set(defaultBytes, forKey: kMaxPacketBytes) }
            let v = ud.integer(forKey: kMaxPacketBytes)
            return v == 0 ? defaultBytes : clamp(v)
        }
        set {
            UserDefaults.standard.set(clamp(newValue), forKey: kMaxPacketBytes)
            notifyChange()
        }
    }

    // MARK: - Utils

    private static func clamp(_ v: Int) -> Int {
        return max(minBytes, min(maxBytes, v))
    }

    /// 可选广播（目前用不着也不碍事）：有些服务层想监听变更的话，用这个通知名
    static let didChange = Notification.Name("FeatureFlags.didChange")

    private static func notifyChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

