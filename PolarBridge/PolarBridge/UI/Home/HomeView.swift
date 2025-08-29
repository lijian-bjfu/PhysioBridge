import SwiftUI

// 用于修改UDP目标地址：端口号格式器（与 DebugView 一致）
fileprivate let homePortFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .none
    f.minimum = 1
    f.maximum = 65535
    return f
}()

// 用于设置修改UDP的键盘。输入焦点与编辑弹窗状态
fileprivate enum UdpFocusField { case host, port }

struct HomeView: View {
    @StateObject private var store = AppStore.shared

    @AppStorage("udpHost") private var udpHost: String = AppConfig.defaultUDPHost
    @AppStorage("udpPort") private var udpPort: Int    = AppConfig.defaultUDPPort
    
    // 受试者与会话编号的本地持久化
    @AppStorage("participantID") private var participantID: String = ""
    @AppStorage("sessionID")     private var sessionID: String = ""
    
    // 统一弹窗类型
    private enum ActiveModal: String, Identifiable {
        case udp, subject
        var id: String { rawValue }
    }

    // 当前激活弹窗；nil 表示无弹窗
    @State private var activeModal: ActiveModal? = nil

    
    // 受试者信息记录页面键盘管理
    @FocusState private var subjectFocus: SubjectField?
    private enum SubjectField { case pid, sid }

    // 用于设置修改UDP的键盘：键盘焦点
    @FocusState private var udpFocus: UdpFocusField?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // === 设置 UDP（置顶显示） ===
                    Text("设置 UDP")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal)

                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            // 当前目标（直接读 AppStorage，随 applyTarget 写回自动刷新）
                            Text("当前 UDP 目标地址：\(udpHost):\(udpPort)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                // 进入编辑弹窗时，带入当前值
                                activeModal = .udp
                            } label: {
                                Text("设置")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Text("请检查接收信号电脑的 Wi-Fi IPv4 地址（例如在“网络偏好设置”或状态栏 Wi-Fi 详情中），替换当前 UDP 目标地址。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal)

                    // 设备区
                    Text("设备")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal)

                    let store = AppStore.shared
                    HStack(spacing: 16) {
                        DeviceCard(
                            title: "Polar Verity Sense",
                            state: store.verityState
                        ) {
                            store.tapDeviceCard("verity")
                        }

                        DeviceCard(
                            title: "Polar H10",
                            state: store.h10State
                        ) {
                            store.tapDeviceCard("h10")
                        }
                    }
                    .padding(.horizontal, 16) 

                    // 选择任务
                    SectionCard {
                        Text("选择任务")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        TaskRow(
                            icon: "person.text.rectangle",
                            title: "受试者信息",
                            subtitle: participantID.isEmpty && sessionID.isEmpty
                                ? "记录被测基本信息"
                                : "PID: \(participantID) · SESSION: \(sessionID)",
                            enabled: true,
                            action: {
                                activeModal = .subject
                            }
                        )

                        Divider()

                        TaskRow(
                            icon: "waveform.path.ecg.rectangle",
                            title: "生理数据采集",
                            subtitle: "采集实验数据",
                            enabled: true
                        ) {
                            CollectView() // 你已有占位即可
                        }

                        Divider()

                        TaskRow(
                            icon: "info.circle",
                            title: "参考信息",
                            subtitle: "硬件与数据信息详情",
                            enabled: true
                        ) {
                            InformationView(viewModel: InformationViewModel(store: AppStore.shared))
                        }
                    }
                    .padding(.horizontal)

                    // 最近数据（占位）
                    SectionCard {
                        Text("历史记录")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        TaskRow(
                            icon: "clock.arrow.circlepath",
                            title: "记录历史",
                            subtitle: "查看历史记录信息",
                            enabled: true
                        ) {
                            HistoryView()   // ← 占位页面
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 16)
            }
            // 设置UDP的弹窗
            .sheet(item: $activeModal) { modal in
                switch modal {
                case .udp:
                    UdpSettingsSheetView(
                        initialHost: udpHost,
                        initialPort: udpPort,
                        onCancel: { activeModal = nil },
                        onConfirm: { host, port in
                            AppStore.shared.applyTarget(host: host, port: port)
                            // AppStorage 会被 applyTarget 写回，HomeView 顶部“当前 UDP 目标地址”自动更新
                            activeModal = nil
                        }
                    )

                case .subject:
                    SubjectInfoSheetView(
                        initialPID: participantID,
                        initialSID: sessionID,
                        onCancel: { activeModal = nil },
                        onConfirm: { pid, sid in
                            // 写回持久化，并广播到 LSL（session_meta + marker）
                            @MainActor func apply() {
                                participantID = pid
                                sessionID = sid
                                AppStore.shared.applyParticipant(pid: pid, sessionID: sid)
                                activeModal = nil
                            }
                            if Thread.isMainThread { apply() } else { DispatchQueue.main.async { apply() } }
                        }
                    )
                }
            }

            // HomeView整体页面的导航栏
            .navigationTitle("生理信号记录")
            .navigationBarTitleDisplayMode(.inline)
            // 扫描设备
            .onAppear {
                AppStore.shared.applyTarget(host: udpHost, port: udpPort)
                print("[HOME] applied UDP target \(udpHost):\(udpPort)")
                PolarManager.shared.startScan(prefix: "Polar")
            }
            .onDisappear {
                PolarManager.shared.stopScan()
            }
        }
    }
}



